import Foundation
import Combine
import AppKit
import ServiceManagement
import Carbon.HIToolbox

/// 全局状态：模型选择、下载源、下载、引擎、翻译。
@MainActor
final class AppState: ObservableObject {

    static let shared = AppState()

    let engine = Engine()
    let downloader = Downloader()
    let updater = EngineUpdater()
    let appUpdater = AppUpdater()
    let hotKey = GlobalHotKey()
    let clipboardMonitor = ClipboardMonitor()

    /// 全局快捷键（可自定义，录制式设置）。keyCode <= 0 表示禁用。
    @Published var hotKeyKeyCode: Int = 17 { // kVK_ANSI_T
        didSet {
            UserDefaults.standard.set(hotKeyKeyCode, forKey: "hotKeyKeyCode")
            reRegisterHotKey()
        }
    }
    @Published var hotKeyModifiers: UInt32 = UInt32(cmdKey | optionKey) { // ⌥⌘
        didSet {
            UserDefaults.standard.set(Int(hotKeyModifiers), forKey: "hotKeyModifiers")
            reRegisterHotKey()
        }
    }
    /// 再次进入翻译弹窗时自动清空输入框（菜单栏弹窗内有开关，设置面板同步）
    @Published var autoClearInput: Bool = false {
        didSet { UserDefaults.standard.set(autoClearInput, forKey: "autoClearInput") }
    }
    /// 启动时自动检查应用（Transend.app）是否有新版本
    @Published var autoCheckAppUpdate: Bool = true {
        didSet { UserDefaults.standard.set(autoCheckAppUpdate, forKey: "autoCheckAppUpdate") }
    }
    /// 选中即翻译：选中文本后按全局快捷键，直接读取选区翻译（需辅助功能权限）
    @Published var selectToTranslate: Bool = false {
        didSet {
            guard started else { return } // 初始化赋值不触发副作用（避免启动即弹权限窗）
            UserDefaults.standard.set(selectToTranslate, forKey: "selectToTranslate")
            if selectToTranslate {
                ensureSelectToTranslatePermission()
            } else {
                accessibilityIssue = nil
            }
        }
    }

    /// 选中即翻译不可用时的提示（nil = 正常或功能关闭）；用菜单栏横幅提示，避免启动弹窗打扰。
    @Published var accessibilityIssue: SelectionReader.PermissionState?

    /// 快捷键的可读显示（如 ⌥⌘T / 已禁用）
    var hotKeyDisplay: String {
        hotKeyKeyCode > 0
            ? shortcutDisplayString(keyCode: hotKeyKeyCode, modifiers: hotKeyModifiers)
            : "已禁用"
    }

    // MARK: - 模型与下载源（UserDefaults 持久化）

    @Published var selectedModelID: String {
        didSet { UserDefaults.standard.set(selectedModelID, forKey: "selectedModelID") }
    }
    @Published var source: DownloadSource {
        didSet { UserDefaults.standard.set(source.rawValue, forKey: "downloadSource") }
    }

    var profiles: [ModelProfile] { ModelProfile.available }
    var selectedProfile: ModelProfile {
        profiles.first { $0.id == selectedModelID } ?? profiles[0]
    }
    var modelDownloaded: Bool {
        selectedProfile.isDownloaded(at: AppPaths.modelURL(for: selectedProfile))
    }

    // MARK: - 翻译

    @Published var input = ""
    @Published var output = ""
    @Published var target: Language = ModelProfile.hyMT2.languages[1] // 默认 English
    @Published var userPickedTarget = false
    @Published var isTranslating = false
    @Published var message: String?

    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
            applyLaunchAtLogin()
        }
    }

    private var started = false

    /// 是否曾成功获得辅助功能授权（用于区分「未授权」与「授权已失效」）。
    private static let axEverGrantedKey = "selectToTranslateEverGranted"

    private init() {
        let ud = UserDefaults.standard
        selectedModelID = ud.string(forKey: "selectedModelID") ?? ModelProfile.available[0].id
        source = DownloadSource(rawValue: ud.string(forKey: "downloadSource") ?? "") ?? .huggingface
        launchAtLogin = ud.object(forKey: "launchAtLogin") as? Bool ?? false
        hotKeyKeyCode = ud.object(forKey: "hotKeyKeyCode") as? Int ?? 17
        hotKeyModifiers = UInt32(ud.object(forKey: "hotKeyModifiers") as? Int ?? Int(cmdKey | optionKey))
        autoClearInput = ud.object(forKey: "autoClearInput") as? Bool ?? false
        autoCheckAppUpdate = ud.object(forKey: "autoCheckAppUpdate") as? Bool ?? true
        selectToTranslate = ud.object(forKey: "selectToTranslate") as? Bool ?? false
        // 迁移：旧版用可执行文件签名记录授权，存在即视为「曾授权过」
        if !ud.bool(forKey: Self.axEverGrantedKey),
           ud.string(forKey: "selectToTranslateTrustedBinary") != nil {
            UserDefaults.standard.set(true, forKey: Self.axEverGrantedKey)
        }
    }

    // MARK: - 启动

    func launch() {
        guard !started else { return }
        started = true
        // 模型未下载：不自动下载，界面顶部橙色引导条指引用户去设置选择下载源
        if modelDownloaded {
            engine.start(profile: selectedProfile)
        }
        // 引擎更新：清理残留更新文件 + 后台检查 llama.cpp 是否有新版本
        // （12 小时内不重复自动检查；发现新版在菜单栏弹窗与设置面板提示，用户可一键安装）
        updater.cleanupStaleFiles()
        updater.autoCheck()
        // 应用更新：清理残留更新工作目录 +（可选）后台检查 Transend 是否有新版本
        appUpdater.cleanupStaleFiles()
        if autoCheckAppUpdate {
            appUpdater.autoCheck()
        }
        // 快捷翻译：全局热键（默认 ⌥⌘T，可在设置中自定义）
        clipboardMonitor.start()
        hotKey.onPress = { [weak self] in
            Task { @MainActor in self?.performQuickAction() }
        }
        if hotKeyKeyCode > 0 {
            hotKey.register(keyCode: UInt32(hotKeyKeyCode), modifiers: hotKeyModifiers)
        }
        // 选中即翻译：刷新辅助功能可用性（不可用时用横幅提示，不弹窗）
        refreshAccessibilityIssue()
    }

    /// 快捷键变更后重新注册（设置界面实时生效）
    private func reRegisterHotKey() {
        guard started else { return }
        hotKey.unregister()
        if hotKeyKeyCode > 0 {
            hotKey.register(keyCode: UInt32(hotKeyKeyCode), modifiers: hotKeyModifiers)
        }
    }

    /// 全局热键动作（优先级）：
    /// 1. 选中即翻译：读取当前前台 App 中选中的文本（需辅助功能权限）
    /// 2. 刚复制/剪切过文本（剪贴板嗅探）
    /// 3. 都没有 → 弹出菜单栏弹窗并聚焦输入框（与点击菜单栏一致）
    func performQuickAction() {
        if selectToTranslate, let selected = SelectionReader.selectedText() {
            axLog("quick action: selection \(selected.count) chars")
            input = selected
            output = ""
            message = nil
            MenuBarController.shared.showPopover(keepInput: true)
            return
        }
        if let text = clipboardMonitor.takeFreshText() {
            input = text
            output = ""
            message = nil
            MenuBarController.shared.showPopover(keepInput: true)
        } else {
            MenuBarController.shared.showPopover()
        }
    }

    // MARK: - 选中即翻译（辅助功能权限）

    /// 启动 / 回到前台时刷新：可用则记「曾授权」，不可用则设置横幅提示（不弹窗打扰）。
    func refreshAccessibilityIssue() {
        guard selectToTranslate else { accessibilityIssue = nil; return }
        if SelectionReader.isFunctional {
            UserDefaults.standard.set(true, forKey: Self.axEverGrantedKey)
            accessibilityIssue = nil
            axLog("refresh: functional")
        } else {
            // 曾授权过 → 授权失效（adhoc 更新后常见）；从未授权 → 未授权
            let everGranted = UserDefaults.standard.bool(forKey: Self.axEverGrantedKey)
            accessibilityIssue = everGranted ? .stale : .denied
            axLog("refresh: not functional, everGranted=\(everGranted) -> \(String(describing: accessibilityIssue))")
        }
    }

    /// 当前辅助功能状态（结合「是否曾授权」区分 stale/denied）。
    private func currentAccessibilityState() -> SelectionReader.PermissionState {
        if SelectionReader.isFunctional {
            UserDefaults.standard.set(true, forKey: Self.axEverGrantedKey)
            return .granted
        }
        return UserDefaults.standard.bool(forKey: Self.axEverGrantedKey) ? .stale : .denied
    }

    /// 用户开启开关时调用（显式操作，可弹窗）。
    func ensureSelectToTranslatePermission() {
        let state = currentAccessibilityState()
        axLog("toggle on: state=\(state)")
        accessibilityIssue = (state == .granted) ? nil : state
        guard state != .granted else { return }
        promptAccessibility(state: state)
    }

    /// 设置面板 / 横幅「修复授权」入口：清除失效记录并触发系统授权。
    /// 只调用系统弹窗（其自带「打开系统设置」按钮），不再另行打开设置页，避免一次弹两个；
    /// 也不立即刷新状态（此时尚未真正授权），回到 App 时按真实状态刷新。
    func repairAccessibility() {
        let state = currentAccessibilityState()
        if state == .stale { SelectionReader.resetPermission() }
        SelectionReader.promptForPermission()
    }

    /// 提示用户授予 / 修复辅助功能权限。
    private func promptAccessibility(state: SelectionReader.PermissionState) {
        axLog("promptAccessibility state=\(state)")
        let alert = NSAlert()
        alert.alertStyle = .informational
        let isStale = state == .stale
        alert.messageText = isStale ? "辅助功能授权已失效" : "需要辅助功能权限"
        var info = "「选中即翻译」需要在按快捷键时读取你选中的文本。"
        if isStale {
            info += "系统里可能仍显示 Transend 已授权，但未签名应用的授权与 App 二进制绑定，更新后会失效。\n点下方按钮会清除失效记录并弹出系统授权提示：在提示里选「打开系统设置」，再打开 Transend 的开关（macOS 不允许程序自动开启，需你手动确认一次）。"
        } else {
            info += "点下方按钮后，在弹出的系统提示里选「打开系统设置」，再打开 Transend 的开关（需你手动确认一次）。"
        }
        alert.informativeText = info
        alert.addButton(withTitle: isStale ? "一键修复" : "去授权")
        alert.addButton(withTitle: "稍后")

        let previous = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if isStale { SelectionReader.resetPermission() }
            SelectionReader.promptForPermission()
        }
        if previous == .accessory { NSApp.setActivationPolicy(.accessory) }
    }

    func shutdown() {
        engine.stop()
        downloader.cancel()
        updater.cancelInstall()
        appUpdater.cancelInstall()
        hotKey.unregister()
        clipboardMonitor.stop()
    }

    // MARK: - 模型切换与下载

    /// 切换模型：停止旧引擎 →（未下载则不启动，橙色引导条指引下载）→ 启动新引擎。
    func switchModel(to id: String) {
        guard id != selectedModelID else { return }
        selectedModelID = id
        engine.stop()
        downloader.cancel()
        // 未下载：不自动下载、不启动，界面顶部橙色引导条指引
        if modelDownloaded {
            engine.start(profile: selectedProfile)
        }
    }

    func downloadSelectedModel() {
        guard !downloader.isDownloading else { return }
        let profile = selectedProfile
        let url = source.url(repoPath: profile.repoPath, fileName: profile.fileName)
        downloader.start(urls: [url], sizeBytes: profile.sizeBytes, dest: AppPaths.modelURL(for: profile)) { [weak self] in
            guard let self else { return }
            self.engine.start(profile: self.selectedProfile)
        }
    }

    // MARK: - 翻译

    func translate() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard engine.isRunning else {
            message = "引擎未就绪（\(engine.state.label)）"
            return
        }
        let lang = userPickedTarget ? target : (containsCJK(text) ? Language(code: "en", english: "English", chinese: "英语") : Language(code: "zh", english: "Chinese", chinese: "中文"))
        isTranslating = true
        output = ""
        message = nil
        Task { [weak self] in
            guard let self else { return }
            var acc = ""
            do {
                for try await chunk in Translator(engine: self.engine, profile: self.selectedProfile)
                    .stream(text, target: lang) {
                    acc += chunk
                    self.output = acc
                }
                if acc.isEmpty { self.message = "引擎无输出，请查看日志" }
            } catch {
                self.message = error.localizedDescription
            }
            self.isTranslating = false
        }
    }

    // MARK: - 菜单栏图标（圆圈 + 大写 T，颜色表示状态）

    var menuIcon: NSImage {
        let color: NSColor
        if downloader.isDownloading {
            color = .systemBlue
        } else {
            switch engine.state {
            case .running: color = .systemGreen
            case .starting: color = .systemOrange
            case .failed: color = .systemRed
            case .stopped: color = .systemGray
            }
        }
        return MenuIcon.render(fill: color)
    }

    // MARK: - 菜单动作

    func toggleEngine() {
        if engine.isRunning {
            engine.stop()
        } else {
            engine.start(profile: selectedProfile)
        }
    }

    func revealModelInFinder() {
        let url = AppPaths.modelURL(for: selectedProfile)
        if !FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([AppPaths.modelsDir])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func openLog() {
        NSWorkspace.shared.open(AppPaths.engineLogURL)
    }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // 非 App 包内运行时忽略（如 swift run 调试）
        }
    }

    private func containsCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) || (0x3040...0x30FF).contains(scalar.value)
        }
    }
}

// MARK: - 快捷键显示格式化（Carbon 虚拟键码 → 可读字符串）

func shortcutDisplayString(keyCode: Int, modifiers: UInt32) -> String {
    var s = ""
    if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
    if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
    if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
    if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
    return s + shortcutKeyName(keyCode)
}

func shortcutKeyName(_ code: Int) -> String {
    keyNames[code] ?? "键\(code)"
}

private let keyNames: [Int: String] = [
    0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
    11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
    18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
    30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
    36: "回车", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
    48: "Tab", 49: "空格", 50: "`", 51: "删除", 53: "Esc",
    96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11", 109: "F10", 111: "F12", 118: "F4", 120: "F2", 122: "F1",
    123: "←", 124: "→", 125: "↓", 126: "↑",
]
