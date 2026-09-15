#!/usr/bin/env bash
# 打包 dmg（拖拽安装样式：Transend.app + Applications 快捷方式）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Transend.app"
VERSION="$(defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo 0.0.1)"
DMG="$ROOT/dist/Transend-$VERSION.dmg"
STAGE="$ROOT/.build/dmg-staging"

[ -d "$APP" ] || { echo "未找到 $APP，先运行 build-app.sh"; exit 1; }

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications" # 拖到 Applications 安装

hdiutil create -volname "Transend" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

echo "完成: $DMG ($(du -h "$DMG" | cut -f1))"
