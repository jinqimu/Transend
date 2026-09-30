# Transend 菜单栏翻译

macOS 菜单栏翻译应用：内置标准 [llama.cpp](https://github.com/ggml-org/llama.cpp) `llama-server`，加载 [unsloth/Hy-MT2-1.8B-GGUF](https://huggingface.co/unsloth/Hy-MT2-1.8B-GGUF) 标准量化模型，后台稳定运行，菜单栏显示状态。

## 特性

- **标准 llama.cpp**：构建时自动取 [llama.cpp](https://github.com/ggml-org/llama.cpp) 官方**最新正式版**（`releases/latest` → `nightly-tag.txt` 快照，如 v0.4.1 → b10964）的 macOS arm64 `llama-server` 二进制打包进 App（无自编译），Metal 全量加速；可用 `LLAMA_VERSION=bXXXXX` 固定版本
- **引擎可更新**：启动时自动检查 llama.cpp 官方**正式版**（v 开头稳定版，不采用 b 开头 pre-release），有新版本时菜单栏弹窗提示，设置中一键「安装更新」——下载官方 release 装到用户数据目录，不修改 App 本身，装完自动重启引擎
- **模型可选**：内置 3 个量化档（IQ2_M 690MB / Q3_K_M 907MB / Q4_K_M 1.08GB），设置中随时切换
- **下载源可选**：HuggingFace / HF Mirror / ModelScope 三选一（ModelScope 对国内网络通常最快），断点续传 + 进度显示
- **选中即翻译（可选）**：设置 →「快捷翻译」开启后，选中任意文本按全局快捷键即可直接翻译（读取系统辅助功能选区，无需先复制；未公证应用更新后需重新授权）
- **极简**：十余个 Swift 文件，无自定义 HTTP 服务 —— 本地 API 就是 llama-server 自带的 OpenAI 兼容接口
- **后台稳定**：引擎崩溃自动重启（指数退避）、启动时清扫残留引擎/端口占用、日志落盘、可选开机自启
- **可换模型**：模型档案抽象（`ModelProfile.swift`），换模型只需新增一个 profile

## 构建

```bash
./Scripts/build-app.sh             # 本地构建：打包 dist/Transend Dev.app（独立 bundle id，避免与 brew 版冲突）
RELEASE=1 ./Scripts/build-app.sh   # 发布构建：打包 dist/Transend.app（CI 用；本地打 dmg/zip 前需先执行）
./Scripts/make-icon.sh             # （可选）重新生成应用图标 Resources/AppIcon.icns
./Scripts/distribute.sh            # 打包分发 zip：dist/Transend-<版本>.zip（需先 RELEASE=1 构建）
./Scripts/make-dmg.sh              # 打包分发 dmg：dist/Transend-<版本>.dmg（需先 RELEASE=1 构建）
```

## 安装（Homebrew）

```bash
brew install --cask jinqimu/tap/transend
```

或：

```bash
brew tap jinqimu/tap
brew install --cask transend
```

> 当前未做 Apple 公证。若首次打开提示“无法验证开发者”，执行
> `xattr -dr com.apple.quarantine /Applications/Transend.app`，或右键 App →「打开」。

也可以直接下载 Release 里的 dmg/zip（见下「分发给朋友」），与 Homebrew 版是同一产物、同一版本号。

## 更新

三种方式，均使用同一个 GitHub Release 产物，版本一致、可混用：

1. **Homebrew 安装**：设置 →「应用更新」点「通过 Homebrew 更新」，或手动

   ```bash
   brew update && brew upgrade --cask transend
   ```

2. **普通安装（dmg/zip）**：应用会自动检查新版本（可在设置 →「应用更新」关闭），
   菜单栏弹窗与设置面板出现提示后点「下载并安装」——自动替换 App 并重启；也支持手动「检查更新」。

3. **引擎更新**（与 App 更新相互独立）：应用另会检查 llama.cpp 引擎新版本，装入用户数据目录，
   不修改 App 包内文件。

## 发布新版本

```bash
# 1. 改版本号：Resources/Info.plist（及各界面版本展示），提交
# 2. 打 tag 触发 GitHub Actions 构建并发布 Release（dmg + zip + checksums.txt）
./Scripts/release.sh <version>
# 3. CI 完成后同步 Homebrew cask（更新 tap 仓库的 version/sha256）
./Scripts/update-cask.sh <version>
```

CI 配置见 `.github/workflows/release.yml`（推送 `v*` tag 触发，macOS arm64 runner 构建）。

## 使用

菜单栏图标（圆圈内大写 T，颜色表示状态：绿=运行中、橙=启动中、蓝=下载中、红=出错、灰=停止）：

- **弹窗（极简）**：输入原文 → 选目标语言（默认自动判断：含 CJK 译为英文，否则译为中文）→ 翻译；底部「打开设置…」进入配置界面
- **设置窗口（独立界面）**：模型量化档选择（未下载点「下载」，实时进度）、下载源、引擎启停、日志、模型目录、开机自启
- 首次启动：自动按所选模型和下载源下载（约 690MB），完成后自动启动引擎

> 注：菜单栏应用（无 Dock 图标）的窗口无法自动获得焦点，打开设置窗口时会短暂显示 Dock 图标，关闭后自动恢复纯菜单栏状态。

## 分发给朋友

```bash
./Scripts/make-dmg.sh         # 推荐：产出 dist/Transend-0.0.1.dmg（约 13MB）
./Scripts/distribute.sh       # 或 zip：dist/Transend-0.0.1.zip（约 12MB）
```

两者都不含模型（690MB 首次启动自动下载）。dmg 双击打开后把 Transend.app 拖进 Applications 即可；zip 解压即可用。AirDrop / 微信 / iCloud / 网盘随便发。**朋友需要知道：**

1. **首次打开**：系统会提示"无法验证开发者"——右键点 App →「打开」→ 再确认一次即可（之后正常双击）。或终端执行 `xattr -dr com.apple.quarantine Transend.app`
2. **仅支持 Apple Silicon**（M 系列芯片）；需要 Intel 版可在构建时改用 `llama-*-bin-macos-x64.tar.gz`
3. 首次启动自动下载模型（约 690MB），国内网络建议设置里选 **HF Mirror** 或 **ModelScope**
4. 引擎是本地 HTTP 服务 `http://127.0.0.1:18632`（OpenAI 兼容）

想完全消除"无法验证开发者"提示，需要 Apple Developer 账号（$99/年）做 Developer ID 签名 + 公证；对朋友间分发，右键打开即可。

## 本地 API

引擎监听 `http://127.0.0.1:18632`（llama-server 原生接口）：

| 接口 | 说明 |
| --- | --- |
| `GET /health` | 健康检查 |
| `GET /v1/models` | 模型列表 |
| `POST /v1/chat/completions` | OpenAI 兼容，流式/非流式均支持 |

提示词使用官方模板（[Hy-MT2 官方仓库](https://github.com/Tencent-Hunyuan/Hy-MT2)）：

```
Translate the following text into {target_lang}. Note that you should only output the translated result without any additional explanation:

{source_text}
```

官方推荐采样参数：`temperature 0.7, top_p 0.6, top_k 20, repetition_penalty 1.05, max_tokens 4096`，无 system prompt。

### 推荐：搭配 TextGO 获得更好的「选中即翻译」体验

Transend 的「选中即翻译」**灵感来自 [TextGO](https://github.com/C5H12O5/TextGO)**——一款成熟的可配置文本选区弹窗工具。

如果你**不开启 Transend 的快捷翻译**（「选中即翻译」默认关闭），推荐安装 **TextGO**：它的选区识别与触发方式更完善（双击、Shift+点击、拖选自动弹出、工具条模式、按规则/文本类型配置动作等），体验更好；此时 Transend 可只作为本地翻译引擎使用。

两者也能组合：在 TextGO 里通过脚本 / 本地 AI 方式调用 Transend 的本地 API（`http://127.0.0.1:18632`，OpenAI 兼容），即可实现「选中 → 本地翻译」。

## 目录

```
Sources/Transend/
  TransendApp.swift      @main + 菜单栏 NSStatusItem/NSPopover + 设置/帮助/版本记录窗口
  AppState.swift         全局状态/模型切换/启动编排
  AppPaths.swift         数据目录/引擎解析/旧目录迁移
  ModelProfile.swift     模型档案列表 + 下载源 + 语言表 + 提示词模板
  Engine.swift           llama-server 子进程管理（自动重启、端口清扫）
  EngineUpdater.swift    引擎（llama.cpp）检查更新与安装
  AppUpdater.swift       应用（Transend.app）检查更新与安装（含 Homebrew 识别）
  SelectionReader.swift  辅助功能读取前台 App 选区（选中即翻译）
  Downloader.swift       模型下载（断点续传、进度）
  GlobalHotKey.swift     全局热键（Carbon）
  Translate.swift        提示词构造 + SSE 流式翻译
  Views.swift            菜单栏弹窗 + 设置界面 + 圆圈 T 图标
Scripts/build-app.sh     打包脚本
Scripts/make-icon.sh     图标生成
Scripts/make-dmg.sh      dmg 打包
Scripts/distribute.sh    分发 zip 打包
Scripts/release.sh       打 tag 触发 CI 发布
Scripts/update-cask.sh   同步 Homebrew tap 的 cask（version/sha256）
.github/workflows/release.yml  推送 v* tag 自动构建发布
CHANGELOG.md             版本变更记录（Release 说明来源）
```
