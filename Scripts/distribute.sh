#!/usr/bin/env bash
# 打包分发 zip（ditto 保留权限/符号链接），输出 dist/Transend-<版本>.zip
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Transend.app"
VERSION="$(defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo 0.0.1)"
ZIP="$ROOT/dist/Transend-$VERSION.zip"

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "完成: $ZIP ($(du -h "$ZIP" | cut -f1))"
