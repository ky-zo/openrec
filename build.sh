#!/bin/bash
set -e

VERSION=$(cat VERSION 2>/dev/null || echo "dev")
echo "Building OpenRec v$VERSION..."

swiftc -O \
    -o meetrec \
    -framework ScreenCaptureKit \
    -framework AVFoundation \
    -framework CoreMedia \
    meetrec.swift

echo "Build complete! Run with: ./meetrec"
echo "Version: $VERSION"
echo ""
echo "Note: On first run, macOS will ask for Screen Recording permission."
echo "Grant it in System Settings > Privacy & Security > Screen Recording"
