#!/bin/bash
set -euo pipefail

APP_NAME="GSD"
VERSION="1.0.0"
DMG_NAME="${APP_NAME}-${VERSION}"
BUILD_DIR="$(pwd)/.build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
DMG_DIR="${BUILD_DIR}/dmg"
DMG_PATH="${BUILD_DIR}/${DMG_NAME}.dmg"

echo "==> Building universal binary (arm64 + x86_64)..."
swift build -c release --arch arm64 --arch x86_64

echo "==> Creating app bundle..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

# Copy binary
cp "${BUILD_DIR}/apple/Products/Release/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

# Copy Info.plist
cp "$(pwd)/Resources/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"

# Copy app icon
cp "$(pwd)/Resources/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"

echo "==> Code signing..."
SIGNING_IDENTITY="${SIGNING_IDENTITY:-"-"}"
codesign --force --deep --options runtime -s "${SIGNING_IDENTITY}" "${APP_BUNDLE}"

echo "==> Creating DMG..."
rm -rf "${DMG_DIR}"
mkdir -p "${DMG_DIR}"
cp -R "${APP_BUNDLE}" "${DMG_DIR}/"
ln -s /Applications "${DMG_DIR}/Applications"

rm -f "${DMG_PATH}"
hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${DMG_DIR}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}"

rm -rf "${DMG_DIR}"

echo ""
echo "==> Done!"
echo "    DMG: ${DMG_PATH}"
echo "    Size: $(du -h "${DMG_PATH}" | cut -f1)"
echo ""
echo "Set SIGNING_IDENTITY env var to sign with a Developer ID."
echo "Without it, the build is ad-hoc signed (right-click > Open to launch)."
