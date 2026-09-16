# Transend 开发规约（AGENTS）

## 版本迭代规则

- 版本号**只在用户明确发起**「新版本 / 升版本 / 迭代版本 / 开始 x.y.z 开发」时才递增；日常改动（修 bug、小功能）不升版本
- 用户**未指定**版本号 → 迭代**小版本（patch）**：0.0.1 → 0.0.2
- 用户**指定**版本号 → 迭代到**指定版本**（如"开始 0.5.0 开发" → 0.5.0）
- 升版时**同步更新**：
  - `Resources/Info.plist`（CFBundleShortVersionString）
  - `Sources/Transend/Views.swift`（设置面板版本行、HelpView 技术信息）
  - `Sources/Transend/Views.swift` 的 `ChangelogView` 新增条目
  - `README.md`「版本变更」记录同步新增条目
  - 产物文件名由打包脚本按 Info.plist 自动生成，无需手动改
- 新版本有实质改动时才追加变更条目；版本刚开未完成时写「（开发中）」

## 交付规则

- **每次完成代码改动后，必须运行 `./Scripts/build-app.sh` 重新构建打包 `dist/Transend.app`**，供用户直接运行试用；不要只跑 `swift build` 验证后就结束（`swift build` 只产出 `.build`，不会更新 `dist`）
- **未经用户明确发版，不要 `git push`**：日常改动只在本地提交，等用户发起发版（`./Scripts/release.sh`）时再统一推送到 GitHub，避免把未发布的改动提前推到远端
- 需要分发产物（dmg/zip）时再额外 `./Scripts/make-dmg.sh` / `./Scripts/distribute.sh`

## 常用命令

- 构建：`./Scripts/build-app.sh`（产物 `dist/Transend.app`）
- 打包 dmg：`./Scripts/make-dmg.sh`（hdiutil 需设备访问权限）
- 打包 zip：`./Scripts/distribute.sh`
- 直接运行二进制（环境变量钩子生效）：`dist/Transend.app/Contents/MacOS/Transend`
- 调试钩子：`HYMT2_OPEN_SETTINGS / HYMT2_OPEN_HELP / HYMT2_OPEN_CHANGELOG = 1` 启动时自动打开对应窗口；`HYMT2_QUICK_TEXT=<文本>` 模拟"刚复制"触发快捷翻译；`HYMT2_UPDATE_ENGINE=1` 启动即检查引擎更新并自动安装（跳过 12h 节流，端到端验证用）；`HYMT2_UPDATE_APP=1` 同理用于应用自身更新（会替换并重启 App，端到端验证用）；`HYMT2_AX_DEBUG=1` 输出辅助功能权限相关日志（查看：`log show --last 2m --predicate 'eventMessage CONTAINS "[TransendAX]"' --style compact`）

## 发布与 Homebrew

- **发布流程**：改 `Resources/Info.plist` 版本 → 提交 → `./Scripts/release.sh <version>`（打 tag `v<version>` 并推送）→ GitHub Actions（`.github/workflows/release.yml`）在 macOS arm64 runner 构建并创建 Release（dmg + zip + checksums.txt）→ `./Scripts/update-cask.sh <version>` 同步 tap 的 cask
- **GitHub**：主仓库 `jinqimu/Transend`；Homebrew tap `jinqimu/homebrew-tap`（cask 源码在 tap 仓库 `Casks/transend.rb`）
- **签名**：目前 ad-hoc（`codesign -s -`），未公证；cask 附 caveats 提示用户 `xattr -dr com.apple.quarantine` / 右键打开（新版 Homebrew 已移除 `--no-quarantine`）。后续提官方 homebrew-cask 前需 Developer ID 签名 + 公证
- **应用自更新**：`AppUpdater.swift` 读 GitHub Release 正式版并与 `CFBundleShortVersionString` 比较；Homebrew 安装（检测 `Caskroom/transend`）时引导 `brew upgrade --cask transend`，普通安装则下载 Release zip 后由辅助脚本替换 App 并重启。发布时务必保证 Release 含 `Transend-<version>.zip`

## 项目要点

- 菜单栏应用（LSUIElement，无 Dock 图标）：手动 `NSStatusItem` + `NSPopover`（内容复用 PopoverView）——不用 SwiftUI MenuBarExtra，因为其 popover 无法程序化弹出（快捷热键也需要右上角弹出）；设置 / 帮助 / 版本记录为手动 NSWindow，关闭联动恢复 `.accessory` 激活策略
- 入口为手动 AppKit 生命周期（`TransendMain.main()` → `NSApplication.run()`），**不使用 SwiftUI `App`/`Settings` 场景**：空的 `Settings { EmptyView() }` 占位场景会成为唯一场景，导致启动时弹出空的 “Transend Settings” 幻影窗口（macOS 的 open-untitled-window 路径）
- 快捷翻译：全局热键（Carbon，默认 ⌥⌘T，设置面板可录制自定义）+ 剪贴板嗅探（1s 轮询 changeCount，1.5s 时间窗），复制过文本则自动填入翻译，否则聚焦输入框
- 选中即翻译（可选，默认关）：`SelectionReader.swift` 用辅助功能读取前台 App 选区（焦点元素 `AXSelectedText`，找不到时按子元素 BFS 兜底，depth≤3 / ≤200 节点），按热键时优先于剪贴板。**权限坑**：① adhoc 签名的 `csreq` 钉在 cdhash 上，App 更新后 TCC 记录与二进制不匹配；② `AXIsProcessTrusted()` 是**进程内缓存**，用户中途授权不会刷新，必须用 `AXIsProcessTrustedWithOptions(nil)` 实时查询；③ `kAXTrustedCheckOptionPrompt` **每进程只弹一次**，`tccutil reset` 后必须**重启进程**才会再弹；④ 授权后当前进程的 AX 连接可能仍是旧的，需重启生效。故判断用「实时 isTrusted + AX 探针」，结合「是否曾授权过」分 granted/denied/stale/needsRestart；`stale` = `tccutil reset` + 重启（`resetAndRelaunch`，新进程启动时补弹授权框）；`needsRestart` = 重启生效；启动/打开弹窗用横幅提示（不弹模态）。线程注意：`selectToTranslate` 的 `didSet` 在 `@Published` + init 赋值时也会触发，用 `guard started` 屏蔽，避免启动即弹权限窗
- 彻底避免更新后需重新授权：需用**稳定签名身份**（Developer ID，或固定自签名证书；`csreq` 变为 `identifier + certificate leaf` 而非 cdhash）；adhoc 无解
- 本地 API 端口 18632 专属；启动时清扫孤儿进程
- 下载源：HuggingFace / HF Mirror / modelscope（国内推荐）
- 回复用户用中文