#!/usr/bin/env bash
# 发布版本：校验 Info.plist 版本 → 打 tag v<version> → 推送触发 GitHub Actions 构建发布。
# 用法：./Scripts/release.sh <version>   （如 ./Scripts/release.sh 0.0.3）
#
# 发布后（CI 完成）记得同步 Homebrew cask：./Scripts/update-cask.sh <version>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-}"

if [ -z "$VERSION" ]; then
    echo "用法: $0 <version>   （如 $0 0.0.3）"
    exit 1
fi

PLIST_VERSION="$(defaults read "$ROOT/Resources/Info.plist" CFBundleShortVersionString)"
if [ "$VERSION" != "$PLIST_VERSION" ]; then
    echo "错误：参数版本 $VERSION 与 Info.plist 中的 $PLIST_VERSION 不一致。"
    echo "      请先在 Resources/Info.plist 更新 CFBundleShortVersionString（及各界面版本展示）。"
    exit 1
fi

if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
    echo "错误：存在未提交改动，请先提交后再发布。"
    git -C "$ROOT" status --short
    exit 1
fi

TAG="v$VERSION"
if git -C "$ROOT" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "错误：tag $TAG 已存在。"
    exit 1
fi

git -C "$ROOT" tag -a "$TAG" -m "Transend $VERSION"
git -C "$ROOT" push origin "$TAG"

echo "已推送 $TAG，GitHub Actions 将自动构建并发布 Release。"
echo "完成后执行 ./Scripts/update-cask.sh $VERSION 同步 Homebrew cask。"
