#!/bin/sh
# Prints the next version (CFBundleShortVersionString) after the highest v* release on github.com/SailfishBrowser/macOS,
# prereleases included: a bug fix adds or bumps a fourth part (0.1.6 -> 0.1.6.1 -> 0.1.6.2), a release bumps the third
# (0.1.6.2 -> 0.1.7) and a minor the second (0.1.6.2 -> 0.2.0). Needs gh.
# Usage: next-version.sh <bug fix|release|minor>
set -eu
KIND="${1:?usage: next-version.sh <bug fix|release|minor>}"
LATEST="$(gh release list -R SailfishBrowser/macOS --exclude-drafts --limit 100 --json tagName \
  --jq '.[].tagName | select(test("^v[0-9]+(\\.[0-9]+){1,3}$")) | ltrimstr("v")' |
  sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | tail -n 1)"
: "${LATEST:?no v* release}"
echo "$LATEST" | awk -F. -v kind="$KIND" '
  kind == "bug fix" { print $1 "." $2 "." $3 + 0 "." $4 + 1; exit }
  kind == "release" { print $1 "." $2 "." $3 + 1; exit }
  kind == "minor" { print $1 "." $2 + 1 ".0"; exit }
  { print "unknown kind " kind > "/dev/stderr"; exit 1 }'
