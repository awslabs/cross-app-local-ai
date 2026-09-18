#!/bin/bash
set -e

# APP_NAME is the user-facing product (FastLang.app / FastLang.dmg). PROJECT
# and SCHEME are the Xcode project/scheme.
APP_NAME="FastLang"
PROJECT="FastLang"
SCHEME="FastLang"
BUILD_DIR="build"
DMG_NAME="${APP_NAME}.dmg"

echo "Building ${APP_NAME}..."

# Clean and build
xcodebuild \
    -project "${PROJECT}.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration Release \
    -derivedDataPath "${BUILD_DIR}/derived" \
    clean build

APP_PATH="${BUILD_DIR}/derived/Build/Products/Release/${APP_NAME}.app"

if [ ! -d "$APP_PATH" ]; then
    echo "Error: App not found at ${APP_PATH}"
    exit 1
fi

echo "App built at: ${APP_PATH}"

# Create a staging folder for the DMG contents
STAGING="${BUILD_DIR}/dmg-staging"
rm -rf "${STAGING}"
mkdir -p "${STAGING}"

cp -r "${APP_PATH}" "${STAGING}/"

# Symlink to /Applications for drag-and-drop install
ln -s /Applications "${STAGING}/Applications"

# Create the DMG
echo "Creating DMG..."
hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${STAGING}" \
    -ov \
    -format UDZO \
    "${BUILD_DIR}/${DMG_NAME}"

echo ""
echo "Done: ${BUILD_DIR}/${DMG_NAME}"
echo ""
echo "Note: Users will need to right-click → Open the first time to bypass Gatekeeper,"
echo "or run: xattr -cr /Applications/${APP_NAME}.app"
