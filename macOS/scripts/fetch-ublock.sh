#!/bin/sh
# Puts uBlock Origin, unpacked, in macOS/Extensions/uBlock0.chromium for the app bundle: the official
# Chromium build of the release below (https://github.com/gorhill/uBlock/releases), checked against its
# SHA-256. The engine loads it as a component extension, whose ID comes from the manifest's "key", so this
# adds one: the public half of a key made for Sailfish, giving ID hlmfmdnmdkgbnjgefkahmafaefinjolo.
# To update, change VERSION and SHA256 (the release asset's digest).
set -eu
VERSION=1.75.0
SHA256=393cf95709d1074d4022970e9014e434395c53a822387f1e25f43be97cf4b582
KEY=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAxKsec6ja7fc/87pMw5Eo+gmHsJ0IdlRz/sUOr+ZJo5lE3c+zdeMaZUmSbrWT9OT3uJrbm07yT3UypEi0xya+88EPjs63zq5Y0wzkoYEqX/CgW6ft0IEM7z84vLVpznBa405LRuRi83Pk8L/VRkjQYvcsVC3kOn+ObHbQXb7mpbHd7COn0UmX6r8O8YrhECYaEXqQfXG9SUFDcsZCX0+Z4zJJyLSLt5WLcCOa7FWMezeV/9elqoVslToc8Q56czrwBRWmJVxxpuMJo7Goof75qNgriN0g7/dWPhHXtuxlwv8q7q6Rsh/+hCsiyDDpNpvfgz3inE6jiW/WtgaDbAfgzQIDAQAB
OUT="$(cd "$(dirname "$0")/.." && pwd)/Extensions"
ZIP="$(mktemp -d)/uBlock0.zip"

curl -fsSL -o "$ZIP" "https://github.com/gorhill/uBlock/releases/download/$VERSION/uBlock0_$VERSION.chromium.zip"
echo "$SHA256  $ZIP" | shasum -a 256 -c -
rm -rf "$OUT/uBlock0.chromium"
mkdir -p "$OUT"
unzip -q "$ZIP" -d "$OUT"
plutil -insert key -string "$KEY" "$OUT/uBlock0.chromium/manifest.json"
rm -r "$(dirname "$ZIP")"
