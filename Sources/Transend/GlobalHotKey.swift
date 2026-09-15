import AppKit
import Carbon.HIToolbox

/// 全局快捷键（Carbon RegisterEventHotKey，无需辅助功能权限）。
/// 菜单栏应用专用：LSUIElement 下同样生效，任何前台 App 中都能触发。
@MainActor
final class GlobalHotKey {

    /// 触发回调（可能在任何线程，实现方自行切主线程）。
    var onPress: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private static let signature = OSType(0x5452_4E53) // 'TRNS'

    /// 注册全局热键。
    /// - Parameters:
    ///   - keyCode: 虚拟键码，如 kVK_ANSI_T（17）
    ///   - modifiers: cmdKey/optionKey/shiftKey/controlKey 组合
    func register(keyCode: UInt32, modifiers: UInt32) {
        unregister()

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                hotKey.onPress?()
                return noErr
            },
            1, &eventSpec, selfPtr, &eventHandler)
        if installStatus != noErr {
            NSLog("Transend: InstallEventHandler 失败 \(installStatus)")
        }

        var hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        let registerStatus = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &hotKeyRef)
        if registerStatus != noErr {
            NSLog("Transend: RegisterEventHotKey 失败 \(registerStatus)（可能被其他应用占用）")
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }
}

/// 剪贴板监控：1 秒轮询 changeCount，记录"上次复制"的时间。
/// 快捷翻译热键据此判断用户是否"刚复制了选中文本"（读剪贴板无需辅助功能权限）。
@MainActor
final class ClipboardMonitor {

    /// 剪贴板变化后，在这段时间内按热键视为"刚复制"
    private let freshWindow: TimeInterval = 1.5

    private var timer: Timer?
    private var lastPolledChangeCount: Int
    private var lastChangeTime = Date.distantPast

    init() {
        lastPolledChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let cc = NSPasteboard.general.changeCount
        if cc != lastPolledChangeCount {
            lastPolledChangeCount = cc
            lastChangeTime = Date()
        }
    }

    /// 最近刚复制的文本（时间窗内且非空纯文本）；否则返回 nil。
    func takeFreshText() -> String? {
        guard Date().timeIntervalSince(lastChangeTime) <= freshWindow else { return nil }
        guard let text = NSPasteboard.general.string(forType: .string) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : text
    }
}