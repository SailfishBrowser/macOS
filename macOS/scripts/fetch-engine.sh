#!/bin/sh
# Puts EngineCore.framework in macOS/Frameworks: the prebuilt one for engine/CHROMIUM_VERSION, from the
# engine-<version> release of github.com/SailfishBrowser/macOS, checked against engine/ENGINE_SHA256.
# With ENGINE_HOST set (user@host), copies the one built on that Mac (engine/scripts/build.sh) instead.
# With ENGINE_CACHE set to a directory, the zip is kept there and downloaded only when missing or not matching.
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
DIR="${ENGINE_CACHE:-$(mktemp -d)}"
mkdir -p "$DIR"
SUM="$(cat "$ROOT/engine/ENGINE_SHA256")  $DIR/$NAME"
if ! echo "$SUM" | shasum -a 256 -c -s - 2>/dev/null; then
  curl -fsSL --retry 3 -o "$DIR/$NAME" "https://github.com/SailfishBrowser/macOS/releases/download/engine-$VERSION/$NAME"
  echo "$SUM" | shasum -a 256 -c -
fi
rm -rf "$OUT/EngineCore.framework"
ditto -x -k "$DIR/$NAME" "$OUT"
[ -n "${ENGINE_CACHE:-}" ] || rm -r "$DIR"
