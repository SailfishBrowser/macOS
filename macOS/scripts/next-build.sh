#!/bin/sh
# Prints the next build number (CFBundleVersion, which Sparkle compares): one more than the newest v* release's
# on github.com/SailfishBrowser/macOS, prereleases included, and above 2762, the last test build. Needs gh.
set -eu
REPO=SailfishBrowser/macOS
TAG="$(gh release list -R "$REPO" --exclude-drafts --limit 100 --json tagName \
  --jq '[.[].tagName | select(startswith("v"))][0] // ""')"
LAST=2762
if [ -n "$TAG" ]; then
  PUBLISHED="$(gh release download "$TAG" -R "$REPO" -p appcast.xml -O - |
    sed -n 's|.*<sparkle:version>\(.*\)</sparkle:version>.*|\1|p' | sort -n | tail -n 1)"
  : "${PUBLISHED:?no sparkle:version in the appcast of $TAG}"
  if [ "$PUBLISHED" -gt "$LAST" ]; then LAST="$PUBLISHED"; fi
fi
echo $((LAST + 1))
