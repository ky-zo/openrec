#!/bin/bash
set -e

# Load build configuration if present
if [ -f ".env.build" ]; then
  source .env.build
fi

VERSION=$(cat VERSION 2>/dev/null || echo "dev")
DISPLAY_VERSION="${VERSION#v}"
BUILD_NUMBER=$(cat BUILD_NUMBER 2>/dev/null || echo "1")
APP_NAME="OpenRec"
BUNDLE_ID="app.openrec.mac"
SIGN_ID="${SIGN_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-openrec-notary}"
NOTARY_KEY_PATH="${NOTARY_KEY_PATH:-}"
NOTARY_KEY_ID="${NOTARY_KEY_ID:-}"
NOTARY_ISSUER_ID="${NOTARY_ISSUER_ID:-}"

if [ -z "$SIGN_ID" ]; then
  SIGN_ID=$(security find-identity -v -p codesigning | awk -F\" '/Developer ID Application/{print $2; exit}')
fi

if [ -z "$SIGN_ID" ]; then
  echo "A Developer ID Application identity is required for a production build." >&2
  exit 1
fi

# Fail before replacing a known-good dist build when notarization credentials
# are missing or inaccessible.
NOTARY_AUTH_ARGS=()
if [ -n "$NOTARY_PROFILE" ] \
  && xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  NOTARY_AUTH_ARGS=(--keychain-profile "$NOTARY_PROFILE")
elif [ -n "$NOTARY_KEY_PATH" ] && [ -n "$NOTARY_KEY_ID" ] && [ -n "$NOTARY_ISSUER_ID" ] \
  && xcrun notarytool history \
    --key "$NOTARY_KEY_PATH" \
    --key-id "$NOTARY_KEY_ID" \
    --issuer "$NOTARY_ISSUER_ID" >/dev/null 2>&1; then
  NOTARY_AUTH_ARGS=(
    --key "$NOTARY_KEY_PATH"
    --key-id "$NOTARY_KEY_ID"
    --issuer "$NOTARY_ISSUER_ID"
  )
else
  echo "Working notarization credentials are required for a production build." >&2
  echo "Use NOTARY_PROFILE, or NOTARY_KEY_PATH + NOTARY_KEY_ID + NOTARY_ISSUER_ID." >&2
  exit 1
fi

echo "Building $APP_NAME.app v$DISPLAY_VERSION..."

# Build the executable
swift build --package-path OpenRecApp -c release

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
    <string>$BUILD_NUMBER</string>
    <key>CFBundleShortVersionString</key>
    <string>$DISPLAY_VERSION</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>OpenRec Authentication</string>
            <key>CFBundleURLSchemes</key>
            <array><string>openrec</string></array>
        </dict>
    </array>
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

echo "Signing app with: $SIGN_ID"
codesign --force --options runtime --timestamp \
  --entitlements "OpenRecApp/OpenRec.entitlements" \
  --sign "$SIGN_ID" \
  "$APP_DIR"
codesign --verify --deep --strict --verbose=4 "$APP_DIR"
codesign -d --entitlements :- "$APP_DIR/Contents/MacOS/$APP_NAME" 2>/dev/null \
  | grep -q "com.apple.security.device.audio-input" \
  || { echo "Required microphone entitlement is missing." >&2; exit 1; }

NOTARY_TEMP_DIR=$(mktemp -d /tmp/openrec-notary.XXXXXX)
cleanup_notary_temp() {
  rm -rf "$NOTARY_TEMP_DIR"
}
trap cleanup_notary_temp EXIT

# Notarize and staple the app before putting it inside the DMG. This lets the
# installed app validate even when Gatekeeper cannot reach Apple's servers.
echo "Notarizing app..."
APP_ARCHIVE="$NOTARY_TEMP_DIR/OpenRec.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$APP_ARCHIVE"
xcrun notarytool submit "$APP_ARCHIVE" "${NOTARY_AUTH_ARGS[@]}" --wait
xcrun stapler staple "$APP_DIR" >/dev/null
xcrun stapler validate "$APP_DIR"
spctl --assess --type execute --verbose=4 "$APP_DIR"

# Create DMG with Applications shortcut
echo "Creating DMG..."
DMG_NAME="OpenRec-$DISPLAY_VERSION.dmg"
DMG_STAGING_DIR="$NOTARY_TEMP_DIR/dmg"
mkdir -p "$DMG_STAGING_DIR"
ditto "$APP_DIR" "$DMG_STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$DMG_STAGING_DIR/Applications"

rm -f "dist/$DMG_NAME"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING_DIR" -ov -format UDZO "dist/$DMG_NAME"

echo "Signing and notarizing DMG..."
codesign --force --timestamp --sign "$SIGN_ID" "dist/$DMG_NAME"
codesign --verify --verbose=4 "dist/$DMG_NAME"
xcrun notarytool submit "dist/$DMG_NAME" "${NOTARY_AUTH_ARGS[@]}" --wait
xcrun stapler staple "dist/$DMG_NAME" >/dev/null
xcrun stapler validate "dist/$DMG_NAME"
spctl --assess --type open --context context:primary-signature --verbose=4 "dist/$DMG_NAME"

# Keep the stable download name byte-for-byte identical to the final,
# notarized/stapled versioned DMG.
cp -f "dist/$DMG_NAME" "dist/OpenRec.dmg"
xcrun stapler validate "dist/OpenRec.dmg"

echo ""
echo "Build complete!"
echo "  App: $APP_DIR"
echo "  DMG: dist/$DMG_NAME"
