#!/bin/bash
# 编译内网连接.app
set -euo pipefail

APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$APP_ROOT/app"
BUILD_DIR="$APP_DIR/build"
# NETLINK_OUT 指定产物目录（默认仓库根目录）；NETLINK_VERSION 写进 Info.plist（发布时由 CI 传入 Tag）。
OUT_DIR="${NETLINK_OUT:-$APP_ROOT}"
APP_BUNDLE="$OUT_DIR/NetLink.app"
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
# 系统菜单和 Finder 里的名字按 lproj 本地化；应用自己的文案在代码里（见 L10n.swift）。
cp -R "$APP_DIR/Resources/"*.lproj "$APP_BUNDLE/Contents/Resources/"

if [ -n "${NETLINK_VERSION:-}" ]; then
  if ! [[ "$NETLINK_VERSION" =~ ^[0-9]+(\.[0-9]+)*([-+][0-9A-Za-z.-]+)?$ ]]; then
    echo "版本号格式不对：$NETLINK_VERSION（应为 1.2.3 这样）" >&2
    exit 1
  fi
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NETLINK_VERSION" "$APP_BUNDLE/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${GITHUB_RUN_NUMBER:-$NETLINK_VERSION}" "$APP_BUNDLE/Contents/Info.plist"
  echo "▸ 版本 $NETLINK_VERSION"
fi

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
