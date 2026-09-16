import Foundation
import AppKit
import ApplicationServices

/// 通过 macOS 辅助功能（Accessibility）读取当前前台 App 中选中的文本。
///
/// 「选中即翻译」依赖它：选中文本 → 按全局快捷键 → 直接读取选区（无需模拟 ⌘C）。
/// 读取选区需要「辅助功能」权限；未授权时返回 nil，调用方回退到原有剪贴板流程。
enum SelectionReader {

    /// 辅助功能授权状态。
    /// - granted：授权有效，可读取选区
    /// - denied：未授权
    /// - stale：系统显示已授权，但授权记录与当前二进制不匹配（未签名应用更新后常见）
    enum PermissionState: Equatable {
        case granted
        case denied
        case stale
    }

    /// 是否已获得辅助功能权限（仅 TCC 层面，可能因 adhoc 更新而"假阳性"）。
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// 是否真实可用：必须 `AXIsProcessTrusted()` 为真 **且** AX API 调用成功。
    ///
    /// 注意：未授权 / 授权失效时，AX 调用返回的错误码并不统一
    /// （实测：未授权返回 -25204 cannotComplete 或 -25208 notImplemented；
    /// 文档中的 -25211 apiDisabled 反而不常见）。故任何非 success/noValue 都视为不可用。
    /// 以 `AXIsProcessTrusted()` 为准是必要的：只看 API 是否成功，会在刚触发系统授权弹窗时误判为"已授权"。
    static var isFunctional: Bool {
        guard AXIsProcessTrusted() else { return false }
        if probe() { return true }
        Thread.sleep(forTimeInterval: 0.05)
        let ok = probe()
        if !ok { axLog("isFunctional: trusted but API probe failed -> not functional") }
        return ok
    }

    /// 授权状态（stale / denied 的细分由调用方结合「是否曾授权」判断）。
    static func permissionState() -> PermissionState {
        if isFunctional { return .granted }
        return AXIsProcessTrusted() ? .stale : .denied
    }

    /// 一次 AX 可用性探针。
    private static func probe() -> Bool {
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            system, kAXFocusedApplicationAttribute as CFString, &value)
        return error == .success || error == .noValue
    }

    /// 清除本 App 的辅助功能授权记录（修复更新后失效的授权），随后可重新授权。
    /// 等价于在「系统设置 → 辅助功能」里移除再添加。
    static func resetPermission() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", bundleID]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    /// 触发系统授权弹窗（把本 App 加入「辅助功能」列表）。
    @discardableResult
    static func promptForPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// 读取当前前台 App 中选中的文本；无权限 / 无选区 / 选区为空时返回 nil。
    /// 会排除本 App 自身（避免读到 Transend 自己输入框里的选区）。
    static func selectedText() -> String? {
        guard AXIsProcessTrusted() else { axLog("selectedText: not trusted"); return nil }
        let system = AXUIElementCreateSystemWide()

        // 排除自身：读取当前焦点 App 的 pid
        if let app = copyElement(system, kAXFocusedApplicationAttribute as CFString),
           let pid = pid(of: app), pid == getpid() {
            axLog("selectedText: focused app is self")
            return nil
        }

        guard let focused = copyElement(system, kAXFocusedUIElementAttribute as CFString),
              let text = copyString(focused, kAXSelectedTextAttribute as CFString) else {
            axLog("selectedText: no focused element or no selected text")
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { axLog("selectedText: empty"); return nil }
        axLog("selectedText: got \(trimmed.count) chars")
        return trimmed
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

// MARK: - 调试日志（HYMT2_AX_DEBUG=1；用 `log show` 查看）

func axLog(_ message: String) {
    guard ProcessInfo.processInfo.environment["HYMT2_AX_DEBUG"] == "1" else { return }
    NSLog("[TransendAX] %@", message)
}
