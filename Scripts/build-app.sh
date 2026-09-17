#!/usr/bin/env bash
# 极简打包脚本：
#   1. 取 llama.cpp 官方「最新正式版」并下载 macOS arm64 二进制（llama-server）
#      （可用 LLAMA_VERSION=bXXXXX 固定版本；缓存于 .build/llama/）
#   2. swift build -c release
#   3. 组装 App 包（引擎内置在 Resources/engine）
#   4. ad-hoc 签名
#
# 默认构建**本地开发版**：dist/Transend Dev.app（bundle id com.transend.app.dev，
#   名字 "Transend Dev"）——避免与 brew 安装版 com.transend.app 在辅助功能(TCC)授权、
#   UserDefaults 上互相冲突。本地 dist 不再构建正式版。
# 发布/CI 用 RELEASE=1 构建正式版：dist/Transend.app（bundle id com.transend.app）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ "${RELEASE:-}" = "1" ]; then
    APP_NAME="Transend"
    BUNDLE_ID="com.transend.app"
    DISPLAY_NAME="Transend"
else
    APP_NAME="Transend Dev"
    BUNDLE_ID="com.transend.app.dev"
    DISPLAY_NAME="Transend Dev"
fi
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
# --- llama.cpp 引擎版本 ---
# 默认取官方「最新正式版」（releases/latest，v 开头、非 pre-release）。
# 官方正式版常不带二进制，只带 nightly-tag.txt（快照标签 bXXXXX），二进制用快照标签下载
# （与 App 内 EngineUpdater 的规则一致）。可用 LLAMA_VERSION=bXXXXX 显式覆盖。
api_get() {
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        curl -fsSL --retry 2 --connect-timeout 15 --max-time 60 \
            -H "Authorization: Bearer ${GITHUB_TOKEN}" "$1"
    else
        curl -fsSL --retry 2 --connect-timeout 15 --max-time 60 "$1"
    fi
}

LLAMA_LABEL=""
if [ -z "${LLAMA_VERSION:-}" ]; then
    echo "==> 解析 llama.cpp 最新正式版"
    tmpjson="$(mktemp)"
    if api_get "https://api.github.com/repos/ggml-org/llama.cpp/releases/latest" > "$tmpjson"; then
        LLAMA_LABEL="$(grep -o '"tag_name": *"[^"]*"' "$tmpjson" | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
        if [ -n "$LLAMA_LABEL" ] && grep -q "llama-${LLAMA_LABEL}-bin-macos-arm64.tar.gz" "$tmpjson"; then
            LLAMA_VERSION="$LLAMA_LABEL"            # 正式版直接带二进制
        elif [ -n "$LLAMA_LABEL" ]; then
            snap="$(api_get "https://github.com/ggml-org/llama.cpp/releases/download/${LLAMA_LABEL}/nightly-tag.txt" | tr -d '[:space:]')" || true
            LLAMA_VERSION="${snap:-$LLAMA_LABEL}"   # 正式版只带快照标签
        fi
    fi
    rm -f "$tmpjson"
fi
if [ -z "${LLAMA_VERSION:-}" ]; then
    echo "错误：无法获取 llama.cpp 最新正式版（可显式指定，如 LLAMA_VERSION=b10964 ./Scripts/build-app.sh）" >&2
    exit 1
fi

TARBALL="llama-${LLAMA_VERSION}-bin-macos-arm64.tar.gz"
LLAMA_SRC_DIR="$ROOT/.build/llama/llama-$LLAMA_VERSION"
LLAMA_BIN="$LLAMA_SRC_DIR/llama-server"
# version.txt 展示：正式版标签 + 快照，如 "v0.4.1 (b10964)"
VERSION_STAMP="$LLAMA_VERSION"
if [ -n "$LLAMA_LABEL" ] && [ "$LLAMA_LABEL" != "$LLAMA_VERSION" ]; then
    VERSION_STAMP="$LLAMA_LABEL ($LLAMA_VERSION)"
fi

echo "==> 1/4 llama.cpp 引擎：${LLAMA_LABEL:+$LLAMA_LABEL → }$LLAMA_VERSION (macOS arm64)"
if [ ! -x "$LLAMA_BIN" ]; then
    mkdir -p "$ROOT/.build/llama"
    if [ ! -f "$ROOT/.build/llama/$TARBALL" ]; then
        for url in \
            "https://ghfast.top/https://github.com/ggml-org/llama.cpp/releases/download/$LLAMA_VERSION/$TARBALL" \
            "https://github.com/ggml-org/llama.cpp/releases/download/$LLAMA_VERSION/$TARBALL"; do
            echo "    尝试 $url"
            if curl -fsSL --retry 3 --max-time 1200 "$url" -o "$ROOT/.build/llama/$TARBALL"; then
                break
            fi
        done
    fi
    tar xzf "$ROOT/.build/llama/$TARBALL" -C "$ROOT/.build/llama"
fi
if [ ! -x "$LLAMA_BIN" ]; then
    echo "错误：引擎解压后未找到 $LLAMA_BIN" >&2
    exit 1
fi

echo "==> 2/4 swift build -c release"
swift build --disable-sandbox --package-path "$ROOT" -c release

echo "==> 3/4 组装 $APP"
rm -rf "$APP" "$DIST/HyMT2.app" # 顺带清理旧名残留
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/engine"
cp "$ROOT/.build/release/Transend" "$APP/Contents/MacOS/"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
# 写入身份（DEV 版用独立 bundle id / 名称，避免与 brew 版冲突）
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $DISPLAY_NAME" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $DISPLAY_NAME" "$APP/Contents/Info.plist"
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
# 整个解压目录拷入（llama-server + 依赖 dylib）
cp -R "$LLAMA_SRC_DIR"/. "$APP/Contents/Resources/engine/"
# 写入引擎版本标记（如 "v0.4.1 (b10964)"），供 App 运行时检测引擎是否需要更新
echo "$VERSION_STAMP" > "$APP/Contents/Resources/engine/version.txt"

echo "==> 4/4 ad-hoc 签名"
codesign --force --deep -s - "$APP"

echo "完成: $APP"
