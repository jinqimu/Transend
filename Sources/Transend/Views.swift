import SwiftUI
import AppKit
import Carbon.HIToolbox

/// 菜单栏图标：圆圈内大写 T（fill 颜色表示状态）。
enum MenuIcon {
    static func render(fill: NSColor) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        return NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(fill.cgColor)
            ctx.fillEllipse(in: rect.insetBy(dx: 1, dy: 1))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 11),
                .foregroundColor: NSColor.white,
            ]
            let t = "T" as NSString
            let ts = t.size(withAttributes: attrs)
            t.draw(
                at: NSPoint(x: (rect.width - ts.width) / 2, y: (rect.height - ts.height) / 2),
                withAttributes: attrs)
            return true
        }
    }
}

// MARK: - 菜单栏弹窗（极简：状态 + 翻译）

struct PopoverView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusHeader
            appUpdateBanner
            engineUpdateBanner
            if state.downloader.isDownloading {
                downloadProgress
            } else if !state.modelDownloaded {
                downloadGuide
            }
            inputField
            actionRow
            outputArea
            Toggle(isOn: $state.autoClearInput) {
                Text("再次进入时自动清空输入")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            footer
        }
        .padding(14)
        .frame(width: 420)
    }

    private var statusHeader: some View {
        HStack(spacing: 8) {
            Image(nsImage: state.menuIcon)
                .frame(width: 16, height: 16)
            Text(state.engine.state.label)
                .font(.callout)
            if state.engine.isRunning {
                Text(":\(String(state.engine.port))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(state.selectedProfile.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// 应用有新版本时的引导条（点击打开设置更新）
    @ViewBuilder
    private var appUpdateBanner: some View {
        if case .updateAvailable(let current, let latest) = state.appUpdater.checkState {
            Button {
                SettingsWindow.show()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.orange)
                    Text("Transend 有新版本 \(latest)（当前 \(current)），点此更新…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
            }
            .buttonStyle(.plain)
        }
    }

    /// 引擎有新版本时的引导条（点击打开设置安装）
    @ViewBuilder
    private var engineUpdateBanner: some View {
        if case .updateAvailable(let current, let latest) = state.updater.checkState {
            Button {
                SettingsWindow.show()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.orange)
                    Text("llama.cpp 引擎有新版本 \(latest)（当前 \(current)），点此安装…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
            }
            .buttonStyle(.plain)
        }
    }

    /// 模型未下载时的引导条
    private var downloadGuide: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.secondary)
            Text("模型未下载（约 \(state.selectedProfile.sizeBytes / 1_000_000)MB）——点「打开设置…」选择下载源并下载")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
    }

    /// 下载中的进度条（与设置面板同步）
    private var downloadProgress: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: state.downloader.progress)
                .controlSize(.small)
            Text("正在下载模型：\(state.downloader.downloadedBytes / 1_000_000)MB / \(state.selectedProfile.sizeBytes / 1_000_000)MB（\(Int(state.downloader.progress * 100))%）")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.blue.opacity(0.10)))
    }

    private var inputField: some View {
        TextField("输入要翻译的文本…", text: $state.input, axis: .vertical)
            .lineLimit(2...6)
            .textFieldStyle(.roundedBorder)
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Picker("目标语言", selection: $state.target) {
                ForEach(state.selectedProfile.languages) { lang in
                    Text(lang.english).tag(lang)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 180)
            .onChange(of: state.target) { state.userPickedTarget = true }

            Spacer()

            if state.isTranslating {
                ProgressView()
                    .controlSize(.small)
            }
            Button(state.isTranslating ? "翻译中…" : "翻译") {
                state.translate()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(state.isTranslating || !state.engine.isRunning)
        }
    }

    private var outputArea: some View {
        ScrollView {
            Text(state.output.isEmpty ? "译文会显示在这里…" : state.output)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(state.output.isEmpty ? Color.secondary : Color.primary)
                .padding(8)
        }
        .frame(minHeight: 90, maxHeight: 240)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let msg = state.message {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
            Divider()
            HStack {
                Button("打开设置…") { SettingsWindow.show() }
                    .controlSize(.small)
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
                    .controlSize(.small)
            }
        }
    }
}

// MARK: - 设置窗口（模型 / 下载源 / 引擎 / 通用）

struct SettingsView: View {
    @EnvironmentObject private var state: AppState

    @State private var isRecordingShortcut = false
    @State private var recordingMonitor: Any?

    var body: some View {
        Form {
            Section("模型") {
                Picker("模型", selection: $state.selectedModelID) {
                    ForEach(state.profiles) { p in
                        Text(p.name).tag(p.id)
                    }
                }
                .onChange(of: state.selectedModelID) {
                    state.switchModel(to: state.selectedModelID)
                }

                Picker("下载源", selection: $state.source) {
                    ForEach(DownloadSource.allCases) { s in
                        Text(s.label).tag(s)
                    }
                }

                if state.downloader.isDownloading {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: state.downloader.progress)
                        HStack {
                            Text("下载中 \(state.downloader.downloadedBytes / 1_000_000)MB / \(state.selectedProfile.sizeBytes / 1_000_000)MB（\(Int(state.downloader.progress * 100))%），断点续传·可取消")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("取消") { state.downloader.cancel() }
                                .controlSize(.small)
                        }
                    }
                } else if !state.modelDownloaded {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("未下载（约 \(state.selectedProfile.sizeBytes / 1_000_000)MB）：先选下载源，再点「下载」。国内网络建议 HF Mirror 或 ModelScope。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("下载") { state.downloadSelectedModel() }
                                .controlSize(.small)
                            Spacer()
                            if let err = state.downloader.error {
                                Text(err).font(.caption).foregroundStyle(.orange)
                                    .lineLimit(1)
                            }
                        }
                    }
                } else {
                    Text("✓ 已下载（文件完整性校验通过）")
                        .font(.caption)
                        .foregroundStyle(.green)
                }

                HStack {
                    Button("模型目录") { state.revealModelInFinder() }
                    Spacer()
                }
            }

            Section("引擎") {
                LabeledContent("状态", value: state.engine.state.label)
                LabeledContent("端口", value: "127.0.0.1:\(String(state.engine.port))")
                LabeledContent("引擎版本", value: state.updater.currentVersionDisplay)
                engineUpdateRow
                HStack {
                    Button(state.engine.isRunning ? "停止引擎" : "启动引擎") {
                        state.toggleEngine()
                    }
                    Spacer()
                    Button("检查更新") { state.updater.checkForUpdates() }
                        .disabled(state.updater.isBusy)
                    Button("打开日志") { state.openLog() }
                }
            }

            Section("应用更新") {
                LabeledContent("当前版本", value: state.appUpdater.currentVersionDisplay)
                if state.appUpdater.isBrewInstall {
                    HStack(spacing: 8) {
                        Button("复制升级命令") { state.appUpdater.copyBrewCommand() }
                            .controlSize(.small)
                        Text(state.appUpdater.brewUpgradeCommand)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .textSelection(.enabled)
                        Spacer()
                    }
                }
                appUpdateRow
                HStack {
                    Button("检查更新") { state.appUpdater.checkForUpdates() }
                        .disabled(state.appUpdater.isBusy)
                    Spacer()
                    Toggle("启动时自动检查", isOn: $state.autoCheckAppUpdate)
                        .toggleStyle(.checkbox)
                }
            }

            Section("快捷翻译") {
                HStack {
                    Text("快捷键")
                    Spacer()
                    Button {
                        if isRecordingShortcut {
                            stopRecordingShortcut()
                        } else {
                            startRecordingShortcut()
                        }
                    } label: {
                        Text(isRecordingShortcut ? "按下新组合键…" : state.hotKeyDisplay)
                            .frame(minWidth: 90)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Toggle("再次进入时自动清空输入", isOn: $state.autoClearInput)
                Text("热键全局生效；录制时按 Esc 取消，按 ⌫ 清除快捷键")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("通用") {
                Toggle("登录时自动启动", isOn: $state.launchAtLogin)
                Button {
                    ChangelogWindow.show()
                } label: {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text("0.1.0")
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }

            Section("帮助") {
                HStack {
                    Text("使用说明、常见问题、故障排查")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("打开帮助") { HelpWindow.show() }
                        .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .frame(minHeight: 380)
    }

    // MARK: - 引擎更新

    /// 引擎更新行：检查状态 / 新版本提示 / 下载安装进度（与菜单栏弹窗提示同步）。
    @ViewBuilder
    private var engineUpdateRow: some View {
        let updater = state.updater
        switch updater.checkState {
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在检查 llama.cpp 新版本…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .upToDate(let current):
            VStack(alignment: .leading, spacing: 2) {
                Text("✓ 已是最新引擎（\(current)）")
                    .font(.caption)
                    .foregroundStyle(.green)
                if let err = updater.errorMessage {
                    Text(err).font(.caption).foregroundStyle(.orange)
                }
            }
        case .updateAvailable(let current, let latest):
            VStack(alignment: .leading, spacing: 6) {
                Text("发现新版本 \(latest)（当前 \(current)）")
                    .font(.caption)
                    .foregroundStyle(.orange)
                switch updater.phase {
                case .downloading(let received, let total):
                    HStack(spacing: 6) {
                        if total > 0 {
                            ProgressView(value: updater.downloadProgress)
                                .controlSize(.small)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                        Text("下载引擎 \(received / 1_000_000)MB\(total > 0 ? "/\(total / 1_000_000)MB" : "")…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("取消") { updater.cancelInstall() }
                            .controlSize(.small)
                    }
                case .extracting:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("正在解压…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .installing:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("正在安装…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .idle:
                    HStack(spacing: 8) {
                        Button("安装更新") { updater.installUpdate() }
                            .controlSize(.small)
                            .disabled(updater.isBusy)
                        if let err = updater.errorMessage {
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .lineLimit(1)
                        }
                    }
                }
            }
        case .failed(let msg):
            Text(msg)
                .font(.caption)
                .foregroundStyle(.orange)
        case .idle:
            Text("尚未检查；点「检查更新」查看 llama.cpp 是否有新版本")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 应用更新

    /// 应用更新行：检查状态 / 新版本提示 / 下载安装进度（与菜单栏弹窗提示同步）。
    /// Homebrew 安装时安装动作走 brew，不自行替换 App 包。
    @ViewBuilder
    private var appUpdateRow: some View {
        let updater = state.appUpdater
        switch updater.checkState {
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在检查 Transend 新版本…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .upToDate(let current):
            VStack(alignment: .leading, spacing: 2) {
                Text("✓ 已是最新版本（\(current)）")
                    .font(.caption)
                    .foregroundStyle(.green)
                if let err = updater.errorMessage {
                    Text(err).font(.caption).foregroundStyle(.orange)
                }
            }
        case .updateAvailable(let current, let latest):
            VStack(alignment: .leading, spacing: 6) {
                Text("发现新版本 \(latest)（当前 \(current)）")
                    .font(.caption)
                    .foregroundStyle(.orange)
                switch updater.phase {
                case .downloading(let received, let total):
                    HStack(spacing: 6) {
                        if total > 0 {
                            ProgressView(value: updater.downloadProgress)
                                .controlSize(.small)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                        Text("下载 \(received / 1_000_000)MB\(total > 0 ? "/\(total / 1_000_000)MB" : "")…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("取消") { updater.cancelInstall() }
                            .controlSize(.small)
                    }
                case .extracting:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("正在解压…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .installing:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("正在安装，应用将自动重启…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .idle:
                    HStack(spacing: 8) {
                        Button(updater.isBrewInstall ? "通过 Homebrew 更新" : "下载并安装") {
                            updater.installUpdate()
                        }
                        .controlSize(.small)
                        .disabled(updater.isBusy)
                        if let err = updater.errorMessage {
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .lineLimit(1)
                        }
                    }
                }
            }
        case .failed(let msg):
            Text(msg)
                .font(.caption)
                .foregroundStyle(.orange)
        case .idle:
            Text("尚未检查；点「检查更新」查看 Transend 是否有新版本")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 快捷键录制

    /// 开始录制：本地监听按键，Esc 取消、⌫ 清除、含修饰键的组合立即生效。
    private func startRecordingShortcut() {
        guard !isRecordingShortcut else { return }
        isRecordingShortcut = true
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard self.isRecordingShortcut else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            if event.keyCode == 53 { // Esc：取消
                self.stopRecordingShortcut()
                return nil
            }
            if event.keyCode == 51 { // ⌫：清除快捷键
                self.state.hotKeyKeyCode = 0
                self.state.hotKeyModifiers = 0
                self.stopRecordingShortcut()
                return nil
            }
            let hasModifier = flags.contains(.command) || flags.contains(.option)
                || flags.contains(.control) || flags.contains(.shift)
            guard hasModifier else { return nil } // 未带修饰键：忽略继续录制

            var carbon: UInt32 = 0
            if flags.contains(.control) { carbon |= UInt32(controlKey) }
            if flags.contains(.option) { carbon |= UInt32(optionKey) }
            if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
            if flags.contains(.command) { carbon |= UInt32(cmdKey) }
            self.state.hotKeyKeyCode = Int(event.keyCode)
            self.state.hotKeyModifiers = carbon
            self.stopRecordingShortcut()
            return nil
        }
    }

    private func stopRecordingShortcut() {
        isRecordingShortcut = false
        if let monitor = recordingMonitor {
            NSEvent.removeMonitor(monitor)
            recordingMonitor = nil
        }
    }
}

// MARK: - 帮助页面

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Transend 帮助")
                    .font(.title2.bold())

                section("快速上手") {
                    numbered([
                        "点菜单栏图标（圆圈 T）→「打开设置…」",
                        "选择下载源（国内网络推荐 modelscope（国内推荐））",
                        "点「下载」：支持断点续传，可随时取消",
                        "下载完成后引擎自动启动，菜单栏图标变绿，即可翻译",
                    ])
                }

                section("快捷翻译") {
                    Text("按全局快捷键（默认 ⌥⌘T，可在设置 → 快捷翻译中录制自定义）：")
                        .foregroundStyle(.secondary)
                    numbered([
                        "刚复制/剪切过文字（如选中文本后 ⌘C）→ 自动填入并翻译",
                        "没有复制内容 → 弹出菜单栏弹窗（与点击菜单栏一致），光标聚焦输入框",
                        "弹窗内可勾选「再次进入时自动清空输入」",
                    ])
                }

                section("菜单栏图标颜色") {
                    colorLegend(
                        ("绿", "引擎运行中"), ("橙", "引擎启动中"), ("蓝", "模型下载中"),
                        ("红", "引擎出错"), ("灰", "引擎未运行")
                    )
                }

                section("翻译") {
                    Text("在弹窗输入原文，默认自动判断语言（含中日韩文字译为英文，否则译为中文）；点开语言下拉可手动选择目标语言（支持 33+ 种）。")
                    Text("提示词与采样参数遵循 Hy-MT2 官方推荐，无需设置。")
                }

                section("常见问题") {
                    faq("下载到一半失败或取消了？",
                        "已下载的部分会保留在模型目录。重新点「下载」会自动断点续传，无需重新开始。")
                    faq("引擎一直启动失败？",
                        "应用启动时会自动清扫占用端口 18632 的残留进程。仍失败可在设置「引擎」区点「停止引擎/启动引擎」重试，或点「打开日志」查看原因。")
                    faq("想换更准的模型？",
                        "设置 → 模型下拉选择 Q3_K_M 或 Q4_K_M（更大但更准），下载完成后自动生效。")
                    faq("如何彻底卸载？",
                        "把 Transend.app 拖入废纸篓即可。如要同时清空缓存与模型（约 0.7–1.1GB），删除 ~/Library/Application Support/Transend。")
                    faq("引擎为什么需要更新？",
                        "引擎（llama.cpp）官方持续迭代，修复崩溃、提速或支持新模型。应用启动时会自动检查官方正式版（v 开头稳定版），有新版本时菜单栏弹窗会有橙色提示；在设置 → 引擎中可一键「安装更新」。更新只写入你的用户数据目录，不修改 App 本身，安装完成后自动重启引擎。")
                    faq("应用怎么更新？",
                        "应用会通过 GitHub Release 自动检查新版本（可在设置 →「应用更新」关闭）。普通安装（dmg/zip）可在设置里点「下载并安装」，自动替换并重启；Homebrew 安装请执行 brew update && brew upgrade --cask transend，两种方式使用同一产物、版本一致。")
                    faq("离线能用吗？",
                        "模型下载完成后完全离线可用，翻译请求不会离开本机。")
                }

                section("技术信息") {
                    LabeledContent("版本", value: "0.1.0")
                    LabeledContent("引擎版本", value: AppState.shared.updater.currentVersionDisplay)
                    LabeledContent("本地 API", value: "http://127.0.0.1:18632（OpenAI 兼容）")
                    LabeledContent("模型目录", value: "~/Library/Application Support/Transend/models")
                    LabeledContent("引擎日志", value: "~/Library/Application Support/Transend/engine.log")
                }

                section("致谢") {
                    Text("引擎：llama.cpp（ggml-org）\n模型：Hy-MT2-1.8B（腾讯混元开源机器翻译）\n量化：unsloth/Hy-MT2-1.8B-GGUF")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 540, height: 620)
    }

    // MARK: 布局辅助

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content()
        }
    }

    private func numbered(_ steps: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                Text("\(i + 1). \(step)")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func colorLegend(_ pairs: (String, String)...) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(pairs, id: \.0) { pair in
                HStack(spacing: 6) {
                    Circle().fill(color(for: pair.0)).frame(width: 10, height: 10)
                    Text("\(pair.0)=\(pair.1)")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func color(for name: String) -> Color {
        switch name {
        case "绿": return .green
        case "橙": return .orange
        case "蓝": return .blue
        case "红": return .red
        default: return .gray
        }
    }

    private func faq(_ q: String, _ a: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Q: \(q)")
                .fontWeight(.medium)
            Text("A: \(a)")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 版本记录页面

struct ChangelogView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("版本记录")
                    .font(.title2.bold())
                Text("当前版本 0.1.0（快速开发版，随时更新）")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                versionBlock("0.1.0", "2026-09-15", [
                    "Homebrew 发布：新增 cask（`brew install --cask jinqimu/transend/transend`），支持 `brew upgrade --cask transend` 更新",
                    "应用自更新：启动时自动检查 GitHub Release 正式版，发现新版在菜单栏弹窗与设置面板提示；普通安装（dmg/zip）可一键「下载并安装」（自动替换并重启），Homebrew 安装引导执行 brew 升级——两者使用同一产物、版本一致",
                    "设置面板新增「应用更新」分区（当前版本/检查/安装进度）与「启动时自动检查」开关；帮助新增「应用怎么更新？」",
                    "工程：新增 GitHub Actions 自动发布（推送 v* tag → 构建 dmg/zip + checksums）、Scripts/release.sh、Scripts/update-cask.sh",
                ])

                versionBlock("0.0.3", "2026-09-03", [
                    "引擎可更新：启动时自动检查 llama.cpp 官方正式版（v 开头稳定版，不采用 b 开头 pre-release），发现新版菜单栏弹窗提示，设置面板一键「安装更新」——带下载/解压进度、可取消、失败自动回滚、镜像加速，装完自动重启引擎，全程不修改 App 包内文件",
                    "修复「模型目录」按钮误放在引擎分区：已归位到「模型」分区",
                    "修复引擎重启循环：更新替换期间旧进程退出的迟到回调不再误触发崩溃重启",
                    "帮助页面新增「引擎为什么需要更新？」常见问题，技术信息同步显示引擎版本",
                ])

                versionBlock("0.0.2", "2026-08-19", [
                    "全局快捷键快捷翻译（默认 ⌥⌘T），设置面板支持录制自定义（Esc 取消 / ⌫ 禁用）",
                    "快捷键唤起与点击菜单栏完全一致：右上角弹出同一个弹窗（NSPopover），不再是独立窗口",
                    "刚复制/剪切过文本 → 弹出弹窗并自动填入翻译（剪贴板嗅探，无需辅助功能权限）",
                    "「再次进入时自动清空输入」开关：翻译弹窗内直接呈现（设置面板同步保留）",
                ])

                versionBlock("0.0.1", "2026-08-19", [
                    "首次进入不再自动下载模型：顶部橙色引导条指引用户进设置选择下载源后手动下载",
                    "下载支持「取消」按钮（已下载部分保留，下次自动断点续传）",
                    "已下载状态严格校验（文件大小一致 + GGUF 头部 magic）：残缺文件正确识别为“未下载”，不再卡在“引擎启动中”",
                    "修复菜单栏弹窗重复下载引导，只保留顶部橙色引导条",
                    "下载源显示名改为“modelscope（国内推荐）”",
                    "下载进度：菜单栏弹窗下载时同步显示进度条；设置面板进度行标注“断点续传·可取消”",
                    "帮助页面：设置面板新增「打开帮助」，含快速上手、图标颜色含义、常见问题、技术信息、致谢",
                    "版本号改为 0.0.x 开发版本；设置面板版本行可点击打开「版本记录」窗口",
                ])

                versionBlock("0.0.0", "2026-08-18", [
                    "更名 Transend、全新应用图标（渐变 squircle + 白圈蓝 T）、DMG 拖拽安装打包",
                    "菜单栏弹窗极简化，配置全部移入独立设置窗口",
                    "引擎启动前端口清扫，修复孤儿进程导致绑定失败",
                ])
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 480, height: 560)
    }

    private func versionBlock(_ version: String, _ date: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(version)（\(date)）")
                .font(.headline)
            ForEach(items, id: \.self) { item in
                Text("• \(item)")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
