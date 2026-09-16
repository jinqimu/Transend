#!/usr/bin/env bash
# 极简打包脚本：
#   1. 下载 llama.cpp 官方 release 的 macOS arm64 二进制（llama-server）
#   2. swift build -c release
#   3. 组装 dist/Transend.app（引擎内置在 Resources/engine）
#   4. ad-hoc 签名
#
# DEV=1：本地开发用独立身份（dist/Transend Dev.app，bundle id com.transend.app.dev，
#        名字 "Transend Dev"），避免与 brew 安装版 com.transend.app 在
#        辅助功能(TCC)授权、UserDefaults 上互相冲突。发布/CI 不要带 DEV。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ "${DEV:-}" = "1" ]; then
    APP_NAME="Transend Dev"
    BUNDLE_ID="com.transend.app.dev"
    DISPLAY_NAME="Transend Dev"
else
    APP_NAME="Transend"
    BUNDLE_ID="com.transend.app"
    DISPLAY_NAME="Transend"
fi
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
LLAMA_VERSION="${LLAMA_VERSION:-b10472}"
TARBALL="llama-${LLAMA_VERSION}-bin-macos-arm64.tar.gz"
LLAMA_BIN="$ROOT/.build/llama/llama-server"
LLAMA_SRC_DIR="$ROOT/.build/llama/llama-$LLAMA_VERSION"

echo "==> 1/4 下载 llama.cpp 官方 release ($LLAMA_VERSION, macOS arm64)"
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
# 写入引擎版本标记（如 b10472），供 App 运行时检测引擎是否需要更新
echo "$LLAMA_VERSION" > "$APP/Contents/Resources/engine/version.txt"

echo "==> 4/4 ad-hoc 签名"
codesign --force --deep -s - "$APP"

echo "完成: $APP"
