#!/bin/sh
# Copies engine/ to the build host, links it into the Chromium checkout as
# src/engine_core and applies engine/patches. Safe to run repeatedly.
set -eu
HOST="${ENGINE_HOST:?set ENGINE_HOST to your build Mac, e.g. user@host}"
ENGINE_DIR="$(cd "$(dirname "$0")/.." && pwd)"

rsync -a --delete --exclude out "$ENGINE_DIR/" "$HOST:engine/"
ssh -o BatchMode=yes "$HOST" 'zsh -l -s' <<'EOF'
set -eu
cd ~/chromium/src
test "$(git describe --tags)" = "$(cat ~/engine/CHROMIUM_VERSION)"
rsync -a --delete ~/engine/src/ engine_core/
grep -qx engine_core .git/info/exclude || echo engine_core >> .git/info/exclude
for p in ~/engine/patches/*.patch; do
  if git apply --reverse --check "$p" 2>/dev/null; then
    echo "already applied: $(basename "$p")"
  else
    git apply "$p"
    echo "applied: $(basename "$p")"
  fi
done
EOF
