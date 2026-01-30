#!/bin/bash
set -e

# Load build configuration if present
if [ -f ".env.build" ]; then
  source .env.build
fi

VERSION=$(cat VERSION 2>/dev/null || echo "dev")
DISPLAY_VERSION="${VERSION#v}"
APP_NAME="OpenRec"
BUNDLE_ID="com.fluar.openrec"
SIGN_ID="${SIGN_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-openrec-notary}"

echo "Building $APP_NAME.app v$DISPLAY_VERSION..."

# Build the executable
cd OpenRecApp
swift build -c release
cd ..

# Create app bundle structure
APP_DIR="dist/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# Copy executable
cp "OpenRecApp/.build/release/OpenRecApp" "$MACOS_DIR/$APP_NAME"

# Copy icon
cp "assets/OpenRec.icns" "$RESOURCES_DIR/AppIcon.icns"

# Create Info.plist
cat > "$CONTENTS_DIR/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>
    <string>$DISPLAY_VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$DISPLAY_VERSION</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>OpenRec needs screen recording permission to capture your screen.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>OpenRec needs microphone access to record your voice.</string>
</dict>
</plist>
EOF

# Optional signing
if [ -z "$SIGN_ID" ]; then
  SIGN_ID=$(security find-identity -v -p codesigning | awk -F\" '/Developer ID Application/{print $2; exit}')
fi

if [ -n "$SIGN_ID" ]; then
  echo "Signing app with: $SIGN_ID"
  codesign --force --options runtime --timestamp \
    --entitlements "OpenRecApp/OpenRec.entitlements" \
    --sign "$SIGN_ID" \
    "$APP_DIR"
  codesign --verify "$APP_DIR"
  # Verify entitlements were applied
  echo "Verifying entitlements..."
  codesign -d --entitlements :- "$APP_DIR/Contents/MacOS/$APP_NAME" 2>/dev/null | grep -q "audio-input" && echo "Entitlements OK" || echo "WARNING: Entitlements missing"
else
  echo "Skipping signing (no Developer ID identity found)."
fi

# Create DMG with Applications shortcut
echo "Creating DMG..."
DMG_NAME="OpenRec-$DISPLAY_VERSION.dmg"
DMG_STAGING_DIR="dist/dmg-$DISPLAY_VERSION"
rm -rf "$DMG_STAGING_DIR"
mkdir -p "$DMG_STAGING_DIR"
cp -R "$APP_DIR" "$DMG_STAGING_DIR/"
ln -s /Applications "$DMG_STAGING_DIR/Applications"

rm -f "dist/$DMG_NAME"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING_DIR" -ov -format UDZO "dist/$DMG_NAME"
cp -f "dist/$DMG_NAME" "dist/OpenRec.dmg"
rm -rf "$DMG_STAGING_DIR"

if [ -n "$NOTARY_PROFILE" ]; then
  echo "Notarizing DMG..."
  xcrun notarytool submit "dist/$DMG_NAME" --keychain-profile "$NOTARY_PROFILE" --wait
  echo "Stapling notarization..."
  xcrun stapler staple "$APP_DIR" >/dev/null
  xcrun stapler staple "dist/$DMG_NAME" >/dev/null
else
  echo "Skipping notarization (NOTARY_PROFILE not set)."
fi

echo ""
echo "Build complete!"
echo "  App: $APP_DIR"
echo "  DMG: dist/$DMG_NAME"
