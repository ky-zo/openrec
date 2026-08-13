#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SVG_PATH="$ROOT_DIR/assets/app-icon.svg"
ASSET_CATALOG="$ROOT_DIR/OpenRec/OpenRec/Assets.xcassets/AppIcon.appiconset"

if ! command -v rsvg-convert >/dev/null 2>&1; then
  echo "rsvg-convert is required (brew install librsvg)." >&2
  exit 1
fi

ICONSET_DIR="$(mktemp -d /tmp/openrec-iconset.XXXXXX)/OpenRec.iconset"
mkdir -p "$ICONSET_DIR"
cleanup_iconset() {
  rm -rf "$(dirname "$ICONSET_DIR")"
}
trap cleanup_iconset EXIT

render_icon() {
  local size="$1"
  local output="$2"
  rsvg-convert --width "$size" --height "$size" "$SVG_PATH" --output "$output"
}

for size in 16 32 64 128 256 512 1024; do
  render_icon "$size" "$ASSET_CATALOG/app-icon-$size.png"
done
render_icon 1024 "$ROOT_DIR/assets/app-icon-1024.png"

cp "$ASSET_CATALOG/app-icon-16.png" "$ICONSET_DIR/icon_16x16.png"
cp "$ASSET_CATALOG/app-icon-32.png" "$ICONSET_DIR/icon_16x16@2x.png"
cp "$ASSET_CATALOG/app-icon-32.png" "$ICONSET_DIR/icon_32x32.png"
cp "$ASSET_CATALOG/app-icon-64.png" "$ICONSET_DIR/icon_32x32@2x.png"
cp "$ASSET_CATALOG/app-icon-128.png" "$ICONSET_DIR/icon_128x128.png"
cp "$ASSET_CATALOG/app-icon-256.png" "$ICONSET_DIR/icon_128x128@2x.png"
cp "$ASSET_CATALOG/app-icon-256.png" "$ICONSET_DIR/icon_256x256.png"
cp "$ASSET_CATALOG/app-icon-512.png" "$ICONSET_DIR/icon_256x256@2x.png"
cp "$ASSET_CATALOG/app-icon-512.png" "$ICONSET_DIR/icon_512x512.png"
cp "$ASSET_CATALOG/app-icon-1024.png" "$ICONSET_DIR/icon_512x512@2x.png"

/usr/bin/iconutil --convert icns "$ICONSET_DIR" --output "$ROOT_DIR/assets/OpenRec.icns"

# Next.js still serves favicon.ico to browsers that request the conventional
# path. Keep it on the same source artwork instead of carrying the stock
# starter triangle.
rm -f "$ROOT_DIR/web/src/app/favicon.ico"
/usr/bin/sips \
  --setProperty format ico \
  "$ASSET_CATALOG/app-icon-256.png" \
  --out "$ROOT_DIR/web/src/app/favicon.ico" >/dev/null

echo "Regenerated OpenRec app, Xcode, and web icons from assets/app-icon.svg"
