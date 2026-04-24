#!/bin/bash
set -euo pipefail

APP_NAME="GSD"
VERSION="1.0.1"
DMG_NAME="${APP_NAME}-${VERSION}"
BUILD_DIR="$(pwd)/.build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
DMG_DIR="${BUILD_DIR}/dmg"
DMG_PATH="${BUILD_DIR}/${DMG_NAME}.dmg"
ZIP_PATH="${BUILD_DIR}/${APP_NAME}-notarize.zip"
ENTITLEMENTS="${BUILD_DIR}/entitlements.plist"

SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: Encore AI Labs, Inc. (96R8Y9KHJP)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-GSD-NOTARY}"

echo "==> Building universal binary (arm64 + x86_64)..."
swift build -c release --arch arm64 --arch x86_64

echo "==> Creating app bundle..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${BUILD_DIR}/apple/Products/Release/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "$(pwd)/Resources/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"
cp "$(pwd)/Resources/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"

cat > "${ENTITLEMENTS}" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
</dict>
</plist>
PLIST

echo "==> Signing with Developer ID + hardened runtime..."
codesign --force --options runtime --timestamp \
    --entitlements "${ENTITLEMENTS}" \
    -s "${SIGNING_IDENTITY}" \
    "${APP_BUNDLE}"

codesign --verify --strict --verbose=2 "${APP_BUNDLE}"

echo "==> Zipping app for notarization..."
rm -f "${ZIP_PATH}"
ditto -c -k --keepParent "${APP_BUNDLE}" "${ZIP_PATH}"

echo "==> Submitting to Apple notary service (this takes 1–5 minutes)..."
xcrun notarytool submit "${ZIP_PATH}" \
    --keychain-profile "${NOTARY_PROFILE}" \
    --wait

echo "==> Stapling ticket to app..."
xcrun stapler staple "${APP_BUNDLE}"
xcrun stapler validate "${APP_BUNDLE}"

rm -f "${ZIP_PATH}" "${ENTITLEMENTS}"

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

echo "==> Notarizing DMG..."
xcrun notarytool submit "${DMG_PATH}" \
    --keychain-profile "${NOTARY_PROFILE}" \
    --wait

echo "==> Stapling ticket to DMG..."
xcrun stapler staple "${DMG_PATH}"
xcrun stapler validate "${DMG_PATH}"

echo ""
echo "==> Done!"
echo "    DMG: ${DMG_PATH}"
echo "    Size: $(du -h "${DMG_PATH}" | cut -f1)"
echo "    SHA256: $(shasum -a 256 "${DMG_PATH}" | cut -d' ' -f1)"
