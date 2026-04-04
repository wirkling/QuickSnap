#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="QuickSnap"
DMG_NAME="$APP_NAME.dmg"

echo "==> Cleaning previous build..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Building $APP_NAME (Release)..."
/usr/bin/xcodebuild \
  -project "$PROJECT_DIR/$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=NO \
  2>&1 | tail -5

# Find the built .app
APP_PATH=$(find "$BUILD_DIR/DerivedData" -name "$APP_NAME.app" -type d | head -1)
if [ -z "$APP_PATH" ]; then
  echo "ERROR: $APP_NAME.app not found in build output"
  exit 1
fi
echo "==> Built: $APP_PATH"

# Create a staging folder for the DMG contents
STAGING_DIR="$BUILD_DIR/dmg-staging"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/"

# Add a symlink to /Applications for drag-to-install
ln -s /Applications "$STAGING_DIR/Applications"

echo "==> Creating DMG..."
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$BUILD_DIR/$DMG_NAME"

echo ""
echo "==> Done! DMG is at:"
echo "    $BUILD_DIR/$DMG_NAME"
echo ""
echo "Note: The tester should right-click > Open the app the first time"
echo "      to bypass Gatekeeper (since it's not notarized)."
