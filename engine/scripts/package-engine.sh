#!/bin/sh
# Zips a built EngineCore.framework, symlinks kept, as the asset of release engine-<version> that
# macOS/scripts/fetch-engine.sh downloads, and prints its SHA-256 for engine/ENGINE_SHA256. Run on the build Mac.
# Usage: package-engine.sh [<framework>] [<output dir>]
#   Defaults: ~/chromium/src/out/Engine/EngineCore.framework and the current directory.
set -eu
FRAMEWORK="${1:-$HOME/chromium/src/out/Engine/EngineCore.framework}"
VERSION="$(cat "$(dirname "$0")/../CHROMIUM_VERSION")"
ZIP="${2:-.}/EngineCore-$VERSION-arm64.zip"

rm -f "$ZIP"
ditto -c -k --keepParent "$FRAMEWORK" "$ZIP"
echo "$ZIP"
shasum -a 256 "$ZIP" | cut -d ' ' -f 1
