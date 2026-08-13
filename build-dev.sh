#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

VERSION="$(cat VERSION 2>/dev/null || echo "dev")"
DISPLAY_VERSION="${VERSION#v}"
BUILD_NUMBER="$(cat BUILD_NUMBER 2>/dev/null || echo "1")"
APP_NAME="OpenRec Dev"
EXECUTABLE_NAME="OpenRecDev"
BUNDLE_ID="app.openrec.mac.dev"
APP_DIR="$SCRIPT_DIR/dist/dev/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
LAUNCH_APP=true
RESET_ONBOARDING=false

usage() {
  cat <<'USAGE'
Usage: ./build-dev.sh [options]

Options:
  --no-launch          Build without opening OpenRec Dev
  --reset-onboarding   Show onboarding again without deleting credentials
  -h, --help           Show this help
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-launch)
      LAUNCH_APP=false
      ;;
    --reset-onboarding)
      RESET_ONBOARDING=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

echo "Building $APP_NAME v$DISPLAY_VERSION..."

swift build --package-path OpenRecApp -c debug

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "OpenRecApp/.build/debug/OpenRecApp" "$MACOS_DIR/$EXECUTABLE_NAME"
cp "assets/OpenRec.icns" "$RESOURCES_DIR/AppIcon.icns"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
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
    <string>$EXECUTABLE_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>OpenRec Authentication</string>
            <key>CFBundleURLSchemes</key>
            <array><string>openrec-dev</string></array>
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
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>OpenRec reads your calendar to pre-fill the meeting name for a call.</string>
    <key>NSCalendarsUsageDescription</key>
    <string>OpenRec reads your calendar to pre-fill the meeting name for a call.</string>
</dict>
</plist>
PLIST

SIGN_ID="${DEV_SIGN_ID:-}"
if [ -z "$SIGN_ID" ]; then
  SIGN_ID="$(security find-identity -v -p codesigning | awk -F\" '/Apple Development:/{print $2; exit}')"
fi
if [ -z "$SIGN_ID" ]; then
  SIGN_ID="$(security find-identity -v -p codesigning | awk -F\" '/Developer ID Application:/{print $2; exit}')"
fi

if [ -z "$SIGN_ID" ]; then
  echo "No stable Apple code-signing identity was found." >&2
  echo "Open Xcode > Settings > Accounts and create an Apple Development certificate." >&2
  echo "A stable signature is required so macOS can remember Screen Recording permission." >&2
  exit 1
fi

echo "Signing with: $SIGN_ID"
codesign --force --options runtime --timestamp=none \
  --entitlements "OpenRecApp/OpenRec.entitlements" \
  --sign "$SIGN_ID" \
  "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

if [ "$RESET_ONBOARDING" = true ]; then
  defaults delete "$BUNDLE_ID" OpenRecOnboardingCompletedV1 >/dev/null 2>&1 || true
fi

echo "Build complete: $APP_DIR"

if [ "$LAUNCH_APP" = true ]; then
  pkill -TERM -x "$EXECUTABLE_NAME" >/dev/null 2>&1 || true
  for _ in {1..30}; do
    if ! pgrep -x "$EXECUTABLE_NAME" >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done
  open "$APP_DIR"
  echo "Launched $APP_NAME. Screen Recording permission should persist across future builds."
fi
