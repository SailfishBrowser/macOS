#!/bin/sh
# Builds EngineCore.framework and the EngineHost test app in out/Engine on the
# build host, inside tmux session "engine". Log: ~/chromium/engine-build.log.
set -eu
HOST="${ENGINE_HOST:?set ENGINE_HOST to your build Mac, e.g. user@host}"

ssh -o BatchMode=yes "$HOST" 'zsh -l -s' <<'EOF'
set -eu
cat > ~/chromium/engine-build.sh <<'BUILD'
set -eux
cd ~/chromium/src
mkdir -p out/Engine
cat > out/Engine/args.gn <<ARGS
is_debug = false
is_component_build = false
dcheck_always_on = false
symbol_level = 0
target_cpu = "arm64"
proprietary_codecs = true
ffmpeg_branding = "Chrome"
ARGS
gn gen out/Engine
time autoninja -C out/Engine chrome_framework
cd out/Engine
rm -rf EngineHost.app
mkdir -p EngineHost.app/Contents/MacOS EngineHost.app/Contents/Frameworks
cp ~/engine/host/Info.plist EngineHost.app/Contents/
ditto EngineCore.framework EngineHost.app/Contents/Frameworks/EngineCore.framework
xcrun swiftc -swift-version 5 -target arm64-apple-macos13 -F . \
  ~/engine/host/main.swift -o EngineHost.app/Contents/MacOS/EngineHost
BUILD
tmux kill-session -t engine 2>/dev/null || true
tmux new-session -d -s engine \
  "zsh -l ~/chromium/engine-build.sh > ~/chromium/engine-build.log 2>&1; echo EXIT=\$? >> ~/chromium/engine-build.log; echo ENGINE_BUILD_DONE >> ~/chromium/engine-build.log"
EOF
echo "building in tmux session 'engine' on $HOST; log: ~/chromium/engine-build.log"
