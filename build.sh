#!/bin/bash
set -e

VERSION=$(cat VERSION 2>/dev/null || echo "dev")
DISPLAY_VERSION="${VERSION#v}"
MODULE_CACHE_DIR="${PWD}/.module-cache"
mkdir -p "$MODULE_CACHE_DIR"
echo "Building OpenRec v$DISPLAY_VERSION..."

swiftc -O \
    -module-cache-path "$MODULE_CACHE_DIR" \
    -o openrec \
    -framework ScreenCaptureKit \
    -framework AVFoundation \
    -framework CoreMedia \
    openrec.swift

ARCH=$(uname -m)
DIST_DIR="dist"
ZIP_NAME="openrec-macos-${ARCH}.zip"

mkdir -p "$DIST_DIR"
zip -j -q "$DIST_DIR/$ZIP_NAME" openrec VERSION

echo "Build complete! Run with: ./openrec"
echo "Release zip: $DIST_DIR/$ZIP_NAME"
echo "Version: $VERSION"
echo ""
echo "Note: On first run, macOS will ask for Screen Recording permission."
echo "Grant it in System Settings > Privacy & Security > Screen Recording"
