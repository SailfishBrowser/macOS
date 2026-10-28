#!/bin/sh
# Builds Release, signs Sailfish.app inside-out and packs it into build/Sailfish.dmg.
# Usage: [VERSION=<x.y.z[.n]>] [BUILD=<n>] package.sh
#   VERSION and BUILD set CFBundleShortVersionString and CFBundleVersion, which Sparkle compares; release.sh passes them.
#   Settings come from the environment, or from scripts/.env.local (gitignored), which is sourced when present:
#   SIGN_IDENTITY: the codesigning identity (hardened runtime, timestamped). Empty picks the keychain's first
#     "Developer ID Application" identity; with none the app is signed ad-hoc without the hardened runtime (for
#     this Mac; elsewhere Gatekeeper blocks it until the quarantine attribute is removed).
#   Notarization credentials, the first set given; with none the app and DMG are not notarized:
#   NOTARY_PROFILE: a notarytool keychain profile, in NOTARY_KEYCHAIN (empty means the login keychain).
#   NOTARY_KEY, NOTARY_KEY_ID, NOTARY_ISSUER: an App Store Connect API key's .p8 file, its ID and its issuer ID.
#   NOTARY_APPLE_ID, NOTARY_PASSWORD, NOTARY_TEAM_ID: an Apple ID, an app-specific password for it and the team ID.
#   PROVISIONING_PROFILE: a Developer ID provisioning profile carrying the passkey entitlement
#     (com.apple.developer.web-browser.public-key-credential); it is embedded in the app and the app is signed with
#     scripts/entitlements/app-passkeys.plist. Empty signs with app.plist and no profile, so passkeys stay off.
#   An identity in a keychain that only the GUI session may use needs this script run inside that session, with the
#   keychain unlocked (release.sh's SIGN_WRAPPER).
#   Needs dmgbuild on PATH: python3 -m venv ~/.dmgbuild && ~/.dmgbuild/bin/pip install dmgbuild==1.6.7, then add
#   ~/.dmgbuild/bin to PATH.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ -f "$ROOT/scripts/.env.local" ]; then . "$ROOT/scripts/.env.local"; fi
OUT="$ROOT/build"
APP="$OUT/DerivedData/Build/Products/Release/Sailfish.app"
ENGINE="$APP/Contents/Frameworks/EngineCore.framework"
ENT="$ROOT/scripts/entitlements"
DMG="$OUT/Sailfish.dmg"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
NOTARY_KEYCHAIN="${NOTARY_KEYCHAIN:-}"
NOTARY_KEY="${NOTARY_KEY:-}"
NOTARY_APPLE_ID="${NOTARY_APPLE_ID:-}"
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"$/\1/p' | head -1)}"

cd "$ROOT"
xcodegen -q
xcodebuild -project Sailfish.xcodeproj -scheme Sailfish -configuration Release \
  -derivedDataPath "$OUT/DerivedData" -clonedSourcePackagesDirPath "$OUT/SourcePackages" -destination generic/platform=macOS -skipMacroValidation -quiet build \
  ${VERSION:+MARKETING_VERSION=$VERSION} ${BUILD:+CURRENT_PROJECT_VERSION=$BUILD}

if [ -n "$IDENTITY" ]; then
  sign() { codesign --force --timestamp --sign "$IDENTITY" "$@"; }
  FULL="-o restrict,library,runtime,kill"
  JIT="-o restrict,kill,runtime"
else
  # Ad-hoc code has no team ID, so the library validation that the hardened
  # runtime implies would reject the framework: sign without runtime options.
  sign() { codesign --force --sign - "$@"; }
  FULL=""
  JIT=""
fi

# Chrome's signing layout (chrome/installer/mac/signing/parts.py): JIT helpers
# drop library validation, which is incompatible with the JIT entitlement.
for lib in "$ENGINE"/Libraries/*.dylib "$APP"/Contents/Frameworks/*.dylib; do
  sign "$lib"
done
for exe in chrome_crashpad_handler app_mode_loader web_app_shortcut_copier; do
  sign $FULL "$ENGINE/Helpers/$exe"
done
for helper in "$ENGINE"/Helpers/*.app; do
  case "$helper" in
    *"Renderer).app" | *"GPU).app") sign $JIT --entitlements "$ENT/helper-jit.plist" "$helper" ;;
    *) sign $FULL "$helper" ;;
  esac
done
sign "$ENGINE"
# Sparkle's XPC services serve sandboxed apps only; its helpers are signed before the framework, without --deep.
rm -rf "$SPARKLE/Versions/B/XPCServices" "$SPARKLE/XPCServices"
sign $FULL "$SPARKLE/Versions/B/Autoupdate"
sign $FULL "$SPARKLE/Versions/B/Updater.app"
sign "$SPARKLE"
for plugin in "$APP"/Contents/PlugIns/*; do
  sign $FULL "$plugin"
done
if [ -n "${PROVISIONING_PROFILE:-}" ]; then
  cp "$PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
  sign $FULL --entitlements "$ENT/app-passkeys.plist" "$APP"
else
  sign $FULL --entitlements "$ENT/app.plist" "$APP"
fi
codesign --verify --deep --strict "$APP"

if [ -n "$NOTARY_PROFILE" ]; then
  notary() { xcrun notarytool "$@" --keychain-profile "$NOTARY_PROFILE" ${NOTARY_KEYCHAIN:+--keychain "$NOTARY_KEYCHAIN"}; }
elif [ -n "$NOTARY_KEY" ]; then
  notary() { xcrun notarytool "$@" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER"; }
elif [ -n "$NOTARY_APPLE_ID" ]; then
  notary() { xcrun notarytool "$@" --apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_PASSWORD" --team-id "$NOTARY_TEAM_ID"; }
fi

# dmgbuild writes the install window's layout (scripts/dmg/dmg.json) into the DMG's .DS_Store, without Finder.
rm -f "$DMG"
dmgbuild -s scripts/dmg/dmg.json Sailfish "$DMG" >/dev/null

if [ -z "$IDENTITY" ]; then
  echo "Signed ad-hoc (no Developer ID Application identity); not notarized: $DMG"
  exit 0
fi
sign "$DMG"
# One submission: notarizing the DMG also issues the ticket of the app inside it. Only the DMG gets the ticket
# stapled, so Gatekeeper looks the app's ticket up online the first time the copy dragged out of it opens.
if command -v notary >/dev/null && notary history >/dev/null 2>&1; then
  notary submit "$DMG" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
  echo "Signed with $IDENTITY and notarized: $DMG"
elif command -v notary >/dev/null; then
  echo "Signed with $IDENTITY; not notarized (notarytool rejected the credentials): $DMG"
else
  echo "Signed with $IDENTITY; not notarized (no notarytool credentials): $DMG"
fi
