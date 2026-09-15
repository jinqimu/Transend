import Foundation
import AppKit
import ApplicationServices

/// 通过 macOS 辅助功能（Accessibility）读取当前前台 App 中选中的文本。
///
/// 「选中即翻译」依赖它：选中文本 → 按全局快捷键 → 直接读取选区（无需模拟 ⌘C）。
/// 读取选区需要「辅助功能」权限；未授权时返回 nil，调用方回退到原有剪贴板流程。
enum SelectionReader {

    /// 是否已获得辅助功能权限。
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// 触发系统授权弹窗（把本 App 加入「辅助功能」列表）。
    @discardableResult
    static func promptForPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// 打开「系统设置 → 隐私与安全性 → 辅助功能」。
    static func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    /// 读取当前前台 App 中选中的文本；无权限 / 无选区 / 选区为空时返回 nil。
    /// 会排除本 App 自身（避免读到 Transend 自己输入框里的选区）。
    static func selectedText() -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()

        // 排除自身：读取当前焦点 App 的 pid
        if let app = copyElement(system, kAXFocusedApplicationAttribute as CFString),
           let pid = pid(of: app), pid == getpid() {
            return nil
        }

        guard let focused = copyElement(system, kAXFocusedUIElementAttribute as CFString),
              let text = copyString(focused, kAXSelectedTextAttribute as CFString) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - AX 工具

    private static func copyElement(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private static func copyString(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }

    private static func pid(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }
}
