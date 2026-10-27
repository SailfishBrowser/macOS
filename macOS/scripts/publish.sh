#!/bin/sh
# Publishes a packaged DMG as release v<version> of github.com/SailfishBrowser/macOS, with Sparkle deltas from the
# latest release's DMG and an appcast for this version, the feed sail.fish/appcast.xml redirects to.
# Usage: publish.sh <version> <build> <dmg> <commit>
#   Needs gh signed in and Sparkle's generate_appcast on PATH. Its EdDSA key comes from SPARKLE_KEY_FILE when set,
#   else from the login keychain. PRERELEASE=1 publishes a prerelease, which releases/latest skips.
set -eu
VERSION="$1"
BUILD="$2"
DMG="$3"
COMMIT="$4"
REPO=SailfishBrowser/macOS
TAG="v$VERSION"
DIST="$(mktemp -d)"
trap 'rm -rf "$DIST"' EXIT

# The previous version's DMG sits beside the new one so generate_appcast makes a delta from it.
if gh release view -R "$REPO" >/dev/null 2>&1; then
  gh release download -R "$REPO" -p 'Sailfish-*.dmg' -D "$DIST"
fi
cp "$DMG" "$DIST/Sailfish-$VERSION-$BUILD.dmg"
generate_appcast ${SPARKLE_KEY_FILE:+--ed-key-file "$SPARKLE_KEY_FILE"} --maximum-versions 1 \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" "$DIST"
mkdir "$DIST/latest"
cp "$DMG" "$DIST/latest/Sailfish.dmg"
# shellcheck disable=SC2046
gh release create "$TAG" -R "$REPO" --target "$COMMIT" --title "Sailfish $VERSION" --notes "Build $BUILD" \
  $(if [ "${PRERELEASE:-0}" = 1 ]; then echo --prerelease; else echo --latest; fi) \
  "$DIST/Sailfish-$VERSION-$BUILD.dmg" "$DIST/latest/Sailfish.dmg" $(find "$DIST" -maxdepth 1 -name '*.delta') \
  "$DIST/appcast.xml"
