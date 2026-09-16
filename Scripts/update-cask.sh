#!/usr/bin/env bash
# 同步 Homebrew cask：从 GitHub Release 取 dmg 的 sha256，更新 tap 仓库里的 Casks/transend.rb。
# 用法：./Scripts/update-cask.sh <version> [tap-dir]
#   tap-dir 默认：$TAP_DIR 或 ../homebrew-tap（与主仓库同级）
#
# 依赖：已发布的 GitHub Release（含 checksums.txt）。CI 完成后运行。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="jinqimu/Transend"
VERSION="${1:-}"
TAP_DIR="${2:-${TAP_DIR:-$ROOT/../homebrew-tap}}"
CASK="$TAP_DIR/Casks/transend.rb"

if [ -z "$VERSION" ]; then
    echo "用法: $0 <version> [tap-dir]   （如 $0 0.0.3）"
    exit 1
fi
if [ ! -f "$CASK" ]; then
    echo "错误：未找到 cask 文件 $CASK"
    exit 1
fi

BASE="https://github.com/$REPO/releases/download/v$VERSION"
CHECKSUMS="$(mktemp)"
trap 'rm -f "$CHECKSUMS"' EXIT

echo "==> 获取 v$VERSION 校验和"
for url in \
    "$BASE/checksums.txt" \
    "https://ghfast.top/$BASE/checksums.txt"; do
    if curl -fsSL --connect-timeout 10 --max-time 30 --retry 1 "$url" -o "$CHECKSUMS"; then
        break
    fi
done

SHA="$(grep "Transend-$VERSION.dmg" "$CHECKSUMS" | awk '{print $1}' | head -1 || true)"
if [ -z "$SHA" ]; then
    echo "错误：未能从 Release 获取 Transend-$VERSION.dmg 的 sha256（Release 是否已发布？）"
    exit 1
fi
echo "    sha256 = $SHA"

echo "==> 更新 $CASK"
/usr/bin/sed -i '' -E \
    -e "s/^([[:space:]]*version )\"[^\"]*\"/\1\"$VERSION\"/" \
    -e "s/^([[:space:]]*sha256 )\"[^\"]*\"/\1\"$SHA\"/" \
    "$CASK"

if git -C "$TAP_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    echo "==> 提交并推送 tap"
    git -C "$TAP_DIR" add Casks/transend.rb
    git -C "$TAP_DIR" commit -m "transend $VERSION"
    git -C "$TAP_DIR" push
else
    echo "提示：$TAP_DIR 不是 git 仓库，未自动提交。"
fi

echo "完成。用户更新：brew update && brew upgrade --cask transend"
