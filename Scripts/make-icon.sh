#!/usr/bin/env bash
# 生成应用图标 Resources/AppIcon.icns（由 make-icon.swift 绘制各尺寸 PNG + iconutil 打包）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICONSET="$ROOT/.build/icon/AppIcon.iconset"

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

swift -module-cache-path "$ROOT/.build/mc" "$ROOT/Scripts/make-icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"

echo "完成: $ROOT/Resources/AppIcon.icns"
