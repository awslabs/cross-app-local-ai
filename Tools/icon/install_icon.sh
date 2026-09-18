#!/bin/bash
#
# Renders PNGs at every size `AppIcon.appiconset` expects and writes the
# matching `Contents.json`. Safe to re-run — overwrites existing files.
#
# Usage:
#   ./Tools/icon/install_icon.sh

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." &> /dev/null && pwd)"
APPICONSET="${REPO_ROOT}/FastLang/Assets.xcassets/AppIcon.appiconset"
GENERATOR="${SCRIPT_DIR}/generate_icon.swift"

if [ ! -d "${APPICONSET}" ]; then
    echo "AppIcon.appiconset not found at ${APPICONSET}" >&2
    exit 1
fi

# macOS icon set sizes. `points @ scale = pixels` per Apple's Human
# Interface Guidelines. We render each size directly from the generator
# so every output is pixel-perfect (no downscaling artifacts).
declare -a ENTRIES=(
    "16    1x  icon_16x16.png"
    "32    2x  icon_16x16@2x.png"
    "32    1x  icon_32x32.png"
    "64    2x  icon_32x32@2x.png"
    "128   1x  icon_128x128.png"
    "256   2x  icon_128x128@2x.png"
    "256   1x  icon_256x256.png"
    "512   2x  icon_256x256@2x.png"
    "512   1x  icon_512x512.png"
    "1024  2x  icon_512x512@2x.png"
)

echo "==> Generating icons"
for entry in "${ENTRIES[@]}"; do
    read -r pixels _ filename <<< "$entry"
    swift "${GENERATOR}" "${pixels}" "${APPICONSET}/${filename}"
done

echo "==> Writing Contents.json"
cat > "${APPICONSET}/Contents.json" << 'EOF'
{
  "images" : [
    { "idiom" : "mac", "scale" : "1x", "size" : "16x16",   "filename" : "icon_16x16.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "16x16",   "filename" : "icon_16x16@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "32x32",   "filename" : "icon_32x32.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "32x32",   "filename" : "icon_32x32@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "128x128", "filename" : "icon_128x128.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "128x128", "filename" : "icon_128x128@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "256x256", "filename" : "icon_256x256.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "256x256", "filename" : "icon_256x256@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "512x512", "filename" : "icon_512x512.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "512x512", "filename" : "icon_512x512@2x.png" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
EOF

echo ""
echo "Done. Rebuild the app (Cmd+B in Xcode or ./Tools/packaging/build_pkg.sh)."
