#!/bin/bash
set -euo pipefail

APP_NAME="GhostPepper"
DMG_NAME="GhostPepper"
BUILD_DIR="build"
DMG_DIR="$BUILD_DIR/dmg"

echo "==> Cleaning..."
rm -rf "$BUILD_DIR"
mkdir -p "$DMG_DIR"

echo "==> Building release..."
xcodebuild -project "$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR/derived" \
  -skipMacroValidation \
  build 2>&1 | tail -5

APP_PATH="$BUILD_DIR/derived/Build/Products/Release/$APP_NAME.app"

if [ ! -d "$APP_PATH" ]; then
  echo "ERROR: Build failed — $APP_PATH not found"
  exit 1
fi

echo "==> Preparing DMG contents..."
cp -R "$APP_PATH" "$DMG_DIR/"
ln -s /Applications "$DMG_DIR/Applications"

echo "==> Creating DMG..."
hdiutil create -volname "$APP_NAME" \
  -srcfolder "$DMG_DIR" \
  -ov -format UDZO \
  "$BUILD_DIR/$DMG_NAME.dmg"

echo "==> Cleaning up..."
rm -rf "$DMG_DIR" "$BUILD_DIR/derived"

echo ""
echo "Done! DMG is at: $BUILD_DIR/$DMG_NAME.dmg"
