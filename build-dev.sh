#!/bin/bash
set -e

VERSION=$(cat VERSION 2>/dev/null || echo "dev")
DISPLAY_VERSION="${VERSION#v}"
APP_NAME="OpenRec"
BUNDLE_ID="com.fluar.openrec"

echo "Building $APP_NAME.app v$DISPLAY_VERSION (dev build, no notarization)..."

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
cat > "$CONTENTS_DIR/Info.plist" << PLIST
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
PLIST

# Sign with ad-hoc signature (no Developer ID needed)
echo "Signing app (ad-hoc)..."
codesign --force --deep --sign - "$APP_DIR"

echo ""
echo "Build complete!"
echo "  App: $APP_DIR"
echo ""
echo "Run with: $APP_DIR/Contents/MacOS/OpenRec"
