#!/bin/bash
# 编译内网连接.app
set -euo pipefail

APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$APP_ROOT/app"
BUILD_DIR="$APP_DIR/build"
APP_BUNDLE="$APP_ROOT/NetLink.app"
EXEC_NAME="NetLink"

echo "▸ 编译"
mkdir -p "$BUILD_DIR/module-cache"
swiftc -parse-as-library -O -swift-version 5 \
  -Xcc -fmodules-cache-path="$BUILD_DIR/module-cache" \
  -framework AppKit \
  -framework SwiftUI \
  -framework ServiceManagement \
  "$APP_DIR"/*.swift \
  -o "$BUILD_DIR/$EXEC_NAME"

echo "▸ 自检"
"$BUILD_DIR/$EXEC_NAME" --self-test | grep -v '^ok' || true
"$BUILD_DIR/$EXEC_NAME" --self-test >/dev/null

echo "▸ 组装 App"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
cp "$BUILD_DIR/$EXEC_NAME" "$APP_BUNDLE/Contents/MacOS/$EXEC_NAME"
cp "$APP_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

ICON_PNG="$BUILD_DIR/icon.png"
ICONSET="$BUILD_DIR/icon.iconset"
if swiftc -O -framework AppKit "$APP_ROOT/scripts/render-icon.swift" -o "$BUILD_DIR/render-icon" \
  && "$BUILD_DIR/render-icon" "$ICON_PNG"; then
  rm -rf "$ICONSET"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_PNG" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$ICON_PNG" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP_BUNDLE/Contents/Resources/icon.icns"
fi

codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null
echo "✓ $APP_BUNDLE"
echo "  打开：open \"$APP_BUNDLE\""
