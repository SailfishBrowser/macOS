#!/bin/sh
# Puts EngineCore.framework in macOS/Frameworks: the prebuilt one for engine/CHROMIUM_VERSION, from the
# engine-<version> release of github.com/SailfishBrowser/macOS, checked against engine/ENGINE_SHA256.
# With ENGINE_HOST set (user@host), copies the one built on that Mac (engine/scripts/build.sh) instead.
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/macOS/Frameworks"
mkdir -p "$OUT"

if [ -n "${ENGINE_HOST:-}" ]; then
  rsync -a --delete "$ENGINE_HOST:chromium/src/out/Engine/EngineCore.framework" "$OUT/"
  exit 0
fi

VERSION="$(cat "$ROOT/engine/CHROMIUM_VERSION")"
NAME="EngineCore-$VERSION-arm64.zip"
TMP="$(mktemp -d)"
curl -fsSL --retry 3 -o "$TMP/$NAME" "https://github.com/SailfishBrowser/macOS/releases/download/engine-$VERSION/$NAME"
echo "$(cat "$ROOT/engine/ENGINE_SHA256")  $TMP/$NAME" | shasum -a 256 -c -
rm -rf "$OUT/EngineCore.framework"
ditto -x -k "$TMP/$NAME" "$OUT"
rm -r "$TMP"
