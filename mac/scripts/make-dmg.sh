#!/bin/bash
# 把 NetLink.app 打成安装镜像：打开后是应用图标加一个「应用程序」快捷方式，拖过去即可。
# 用法：mac/scripts/make-dmg.sh <NetLink.app 路径> <输出 .dmg 路径>
set -euo pipefail

APP="${1:?用法：make-dmg.sh <NetLink.app> <输出.dmg>}"
OUT="${2:?用法：make-dmg.sh <NetLink.app> <输出.dmg>}"

[ -d "$APP" ] || { echo "找不到 $APP" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# ditto 保留应用包里的元数据和签名
ditto "$APP" "$STAGE/NetLink.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$OUT"
hdiutil create -volname "NetLink" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
echo "✓ $OUT"
