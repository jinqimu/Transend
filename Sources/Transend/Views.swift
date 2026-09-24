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

// MARK: - 动态高度多行输入框

/// 多行输入框：高度随内容增长（`minLines` 起），超过 `maxLines` 后内部滚动。
/// 占位符由 `PlaceholderTextView` 自绘在文本起始位置，保证与光标精确对齐。
private struct GrowingTextInput: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = PlaceholderTextView()
        textView.placeholder = placeholder
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = NSFont.preferredFont(forTextStyle: .body)
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? PlaceholderTextView else { return }
        textView.placeholder = placeholder
        if textView.string != text {
            textView.string = text
            textView.needsDisplay = true
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            textView.needsDisplay = true
        }
    }
}

/// NSTextView 子类：在文本起始位置绘制占位符（与光标同一坐标，天然对齐）。
private final class PlaceholderTextView: NSTextView {
    var placeholder: String = ""

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        let inset = textContainerInset
        let rect = NSRect(
            x: inset.width,
            y: inset.height,
            width: max(0, bounds.width - inset.width * 2),
            height: max(0, bounds.height - inset.height * 2))
        (placeholder as NSString).draw(in: rect, withAttributes: attributes)
    }
}

// MARK: - 菜单栏弹窗（极简：状态 + 翻译）

struct PopoverView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusHeader
            accessibilityBanner
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
                Text("再次进入时自动清空输入输出")
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

    /// 选中即翻译不可用（未授权 / 授权失效）时的提示条：点此修复或授权
    @ViewBuilder
    private var accessibilityBanner: some View {
        if state.selectToTranslate, let issue = state.accessibilityIssue {
            Button {
                state.repairAccessibility()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(bannerText(issue))
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

    private func bannerText(_ issue: SelectionReader.PermissionState) -> String {
        switch issue {
        case .stale: return "选中即翻译：辅助功能授权已失效，点此一键修复…"
        case .needsRestart: return "选中即翻译：已授权，需重启 Transend 生效，点此重启…"
        case .denied: return "选中即翻译：请在系统设置授权辅助功能，点此处理…"
        case .granted: return ""
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
        GrowingTextInput(text: $state.input, placeholder: "输入要翻译的文本…")
            .frame(height: inputEditorHeight)
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
    }

    /// 输入框高度：1–5 行，超出内部滚动。
    private var inputEditorHeight: CGFloat {
        let font = NSFont.preferredFont(forTextStyle: .body)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let usableWidth: CGFloat = 376 // 弹窗内容 392 - 外 padding 8 - textContainerInset 8
        let attr = NSAttributedString(string: state.input.isEmpty ? " " : state.input,
                                      attributes: [.font: font])
        let rect = attr.boundingRect(
            with: NSSize(width: usableWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        let lines = max(1, min(5, Int(ceil(rect.height / max(lineHeight, 1)))))
        return CGFloat(lines) * lineHeight + 12 // textContainerInset 上下 6*2
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
                .padding(.trailing, 28) // 给复制按钮留位
        }
        .frame(minHeight: 90, maxHeight: 240)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(alignment: .topTrailing) {
            if !state.output.isEmpty {
                Button {
                    copyOutput()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .padding(6)
                .help("复制全部译文（⌘C 复制选中的部分）")
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
    }

    /// 复制全部译文到剪贴板。
    private func copyOutput() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(state.output, forType: .string)
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
                Toggle("再次进入时自动清空输入输出", isOn: $state.autoClearInput)
                Toggle("选中即翻译", isOn: $state.selectToTranslate)
                if state.selectToTranslate {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(state.accessibilityIssue == nil ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(axLabel(state.accessibilityIssue))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let issue = state.accessibilityIssue {
                            Button(repairLabel(issue)) {
                                state.repairAccessibility()
                            }
                            .controlSize(.small)
                        }
                    }
                }
                Text("热键全局生效；录制时按 Esc 取消，按 ⌫ 清除快捷键")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if state.selectToTranslate {
                    Text("选中文本 → 按快捷键即可翻译；首次需在系统设置里打开 Transend 开关。更新/授权失效时点「一键修复」会重启 App 并弹出系统授权提示，再打开开关即可")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("通用") {
                Toggle("登录时自动启动", isOn: $state.launchAtLogin)
                Button {
                    ChangelogWindow.show()
                } label: {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text("0.1.6")
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
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

            Section("帮助") {
                HStack {
                    Text("使用说明、常见问题、故障排查")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("打开帮助") { HelpWindow.show() }
                        .controlSize(.small)
                }
                HStack {
                    Text("项目主页")
                    Spacer()
                    Link("github.com/jinqimu/Transend",
                         destination: URL(string: "https://github.com/jinqimu/Transend")!)
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .frame(minHeight: 380)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state.refreshAccessibilityIssue()
        }
    }

    /// 辅助功能权限状态文案。
    private func axLabel(_ issue: SelectionReader.PermissionState?) -> String {
        switch issue {
        case .none, .some(.granted): return "辅助功能权限：已授权"
        case .some(.denied): return "辅助功能权限：未授权"
        case .some(.stale): return "辅助功能权限：授权已失效（需重新授权）"
        case .some(.needsRestart): return "辅助功能权限：已授权（需重启生效）"
        }
    }

    /// 辅助功能修复按钮文案。
    private func repairLabel(_ issue: SelectionReader.PermissionState) -> String {
        switch issue {
        case .stale: return "一键修复"
        case .needsRestart: return "重启生效"
        case .denied: return "去授权"
        case .granted: return "已授权"
        }
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
                        "弹窗内可勾选「再次进入时自动清空输入输出」",
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
                    faq("「选中即翻译」怎么用？",
                        "设置 → 快捷翻译中开启后：选中任意文本 → 按全局快捷键，即可直接翻译（无需先复制）。首次需在「系统设置 → 隐私与安全性 → 辅助功能」列表里打开 Transend 的开关（macOS 不允许程序自动开启，需手动确认一次）。因应用未做 Apple 公证，辅助功能权限与二进制绑定，每次更新后可能失效——若系统里显示已授权却仍无法翻译，点设置的「一键修复」会重启 App 并弹出系统授权提示，再打开开关即可（授权后 macOS 需重启 App 才生效）。")
                    faq("离线能用吗？",
                        "模型下载完成后完全离线可用，翻译请求不会离开本机。")
                }

                section("技术信息") {
                    LabeledContent("版本", value: "0.1.6")
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
                Text("当前版本 0.1.6（快速开发版，随时更新）")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                versionBlock("0.1.6", "2026-09-24", [
                    "弹窗输入框：改为动态高度（默认 1 行、最多 5 行，超出内部滚动），占位符与光标精确对齐（NSTextView 自绘）",
                    "「再次进入时自动清空输入」→ 同时清空输入与输出",
                    "输出区新增「复制」按钮（复制全部译文）；新增最小「编辑」主菜单，选中输出后 ⌘C 可复制选中部分，输入框 ⌘V/⌘A 等也可用",
                    "工程：本地 dist 默认只构建 Transend Dev.app（独立身份），正式版改由 CI 用 RELEASE=1 构建",
                ])

                versionBlock("0.1.5", "2026-09-17", [
                    "修复飞书 / Electron 选区读不到：去掉「选区范围为 0 就跳过 ⌘C 兜底」——Electron 焦点元素常报 0 长度但实际有选区",
                    "前台 App 切换时提前启用浏览器 / Electron 的无障碍树（`AXEnhancedUserInterface` / `AXManualAccessibility`）",
                    "⌘C 兜底逐项对齐 TextGO：备份全部格式 → 清空剪贴板 → 释放修饰键 + 显式 ⌘C → 每 5ms 轮询（自适应 200–1000ms）→ 还原剪贴板",
                    "构建：内置 llama.cpp 引擎改为构建时取官方最新正式版（不再写死版本），当前 v0.4.1（b10964）",
                ])

                versionBlock("0.1.4", "2026-09-16", [
                    "选中即翻译对齐 TextGO：AX 读不到选区时兜底**模拟 ⌘C 复制并读剪贴板**（读完还原原剪贴板），Safari 等 AX 选区不可靠的 App 现在也能用",
                    "浏览器/Electron：读取前启用 `AXEnhancedUserInterface`（Chrome）/ `AXManualAccessibility`（Electron），并按子元素遍历（depth≤6/≤300 节点）兜底",
                    "兜底前释放触发热键按住的修饰键（避免 ⌘C 变成 ⌥⌘C）；无选区（选区范围长度为 0）时跳过兜底不白等",
                ])

                versionBlock("0.1.3", "2026-09-16", [
                    "修复：授权成功后「选中即翻译」仍不可用——`AXIsProcessTrusted()` 是进程内缓存，用户中途授权不会刷新，改用实时查询 `AXIsProcessTrustedWithOptions(nil)`",
                    "修复：「一键修复」在同一进程里再弹授权框是空操作（`kAXTrustedCheckOptionPrompt` 每进程只弹一次）——改为 `tccutil reset` + 重启 App，由新进程补弹授权提示",
                    "新增「授权已生效，需重启 App」状态与「重启生效」按钮（授权后当前进程 AX 连接可能仍是旧的）",
                    "选区读取增加子元素遍历兜底（兼容浏览器 / Electron 等焦点元素不直接暴露选区的 App）",
                ])

                versionBlock("0.1.2", "2026-09-16", [
                    "修复：开启「选中即翻译」后启动会弹出空的权限窗口——`selectToTranslate` 的 didSet 在初始化赋值时也会触发，改用 guard 屏蔽",
                    "修复：明明未授权 / 授权失效，设置里却显示「已授权」——改为必须系统已信任且 AX 探针成功才算授权",
                    "辅助功能状态改为功能探针（实测未授权返回 -25204/-25208），并结合「是否曾授权过」区分未授权 / 授权失效",
                    "「一键修复」只弹系统授权提示（不再同时打开设置页），并明确提示需在系统设置里手动打开开关；未授权/失效时菜单栏弹窗用橙色横幅提示，不再启动弹窗打扰",
                    "新增 HYMT2_AX_DEBUG 调试日志",
                ])

                versionBlock("0.1.1", "2026-09-15", [
                    "「选中即翻译」（可选，默认关）：选中文本 → 按全局快捷键直接翻译（读取系统辅助功能选区，无需先复制）。首次需在系统设置授权辅助功能；未公证应用权限与二进制绑定，更新后会重新提示授权",
                    "设置调整：「应用更新」分区移至「通用」与「帮助」之间；帮助分区新增「项目主页」（GitHub）链接",
                    "修复：启动时弹出空的 “Transend Settings” 幻影窗口——入口改为纯 AppKit 生命周期，并拒绝无标题窗口与状态恢复",
                    "工程：Homebrew tap 迁移到 jinqimu/homebrew-tap（tap 名 jinqimu/tap），安装命令 brew install --cask jinqimu/tap/transend",
                ])

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
