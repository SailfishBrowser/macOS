#!/bin/sh
# Releases Sailfish from this Mac, the fallback for .github/workflows/release.yml: builds, signs and notarizes a
# commit with the published engine, then publishes it with publish.sh as release v<version> of
# github.com/SailfishBrowser/macOS.
# Usage: release.sh <version> [<commit>]
#   Needs gh signed in, Sparkle's generate_appcast on PATH with its EdDSA key in the login keychain, a Developer ID
#   Application identity and notarytool credentials.
#   Settings come from the environment, or from scripts/.env.local (gitignored), which is sourced when present and
#   copied into the build: SIGN_IDENTITY and the NOTARY_* settings of package.sh, and SIGN_WRAPPER, an optional
#   command prefix for package.sh, e.g. one that unlocks the signing keychain inside the GUI session.
set -eu
SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPTS/.env.local" ]; then . "$SCRIPTS/.env.local"; fi
VERSION="${1:?usage: release.sh <version> [<commit>]}"
TOP="$(git -C "$SCRIPTS" rev-parse --show-toplevel)"
SHA="$(git -C "$TOP" rev-parse "${2:-HEAD}^{commit}")"

fail() { echo "release.sh: $*" >&2; exit 1; }
command -v generate_appcast >/dev/null || fail "Sparkle's generate_appcast is not on PATH"
command -v dmgbuild >/dev/null || fail "dmgbuild is not on PATH (see package.sh)"
gh auth status >/dev/null 2>&1 || fail "gh is missing or not signed in"
security find-generic-password -s https://sparkle-project.org -a ed25519 >/dev/null 2>&1 ||
  fail "no Sparkle EdDSA key in the login keychain"
[ -n "${NOTARY_PROFILE:-}${NOTARY_KEY:-}${NOTARY_APPLE_ID:-}" ] || fail "no notarytool credentials (see package.sh)"
! gh release view "v$VERSION" -R SailfishBrowser/macOS >/dev/null 2>&1 || fail "release v$VERSION exists"
BUILD="$(sh "$SCRIPTS/next-build.sh")"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
git -C "$TOP" archive "$SHA" macOS engine | tar -x -C "$WORK"
if [ -f "$SCRIPTS/.env.local" ]; then cp "$SCRIPTS/.env.local" "$WORK/macOS/scripts/"; fi
cd "$WORK/macOS"
sh scripts/fetch-engine.sh
sh scripts/fetch-ublock.sh
${SIGN_WRAPPER:-} env PATH="$PATH" VERSION="$VERSION" BUILD="$BUILD" sh scripts/package.sh
xcrun stapler validate build/Sailfish.dmg || fail "the DMG is not notarized"
sh scripts/publish.sh "$VERSION" "$BUILD" build/Sailfish.dmg "$SHA"
