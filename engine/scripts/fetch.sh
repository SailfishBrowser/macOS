#!/bin/sh
# Copies the built EngineCore.framework (with its helpers) and the EngineHost
# test app from the build host to engine/out.
set -eu
HOST="${ENGINE_HOST:?set ENGINE_HOST to your build Mac, e.g. user@host}"
OUT="$(cd "$(dirname "$0")/.." && pwd)/out"

mkdir -p "$OUT"
for item in EngineCore.framework EngineHost.app; do
  rsync -a --delete "$HOST:chromium/src/out/Engine/$item" "$OUT/"
done
