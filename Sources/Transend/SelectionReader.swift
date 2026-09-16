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

    /// 真实可用性探测：不仅看 TCC，还实际调用一次 AX API。
    ///
    /// 注意：未授权 / 授权失效时，AX 调用返回的错误码并不统一
    /// （实测：未授权返回 -25204 cannotComplete 或 -25208 notImplemented；
    /// 文档中的 -25211 apiDisabled 反而不常见）。所以**任何非 success/noValue 都视为不可用**，
    /// 再用 `AXIsProcessTrusted()` 区分「未授权」与「授权失效（stale）」。
    static func permissionState() -> PermissionState {
        var lastRaw: Int32 = 0
        for _ in 0..<2 {
            let (usable, error) = probe()
            if usable { return .granted }
            lastRaw = error.rawValue
            Thread.sleep(forTimeInterval: 0.05)
        }
        let trusted = AXIsProcessTrusted()
        axLog("permissionState: probe failed (last error \(lastRaw)), isTrusted=\(trusted) -> \(trusted ? "stale" : "denied")")
        return trusted ? .stale : .denied
    }

    /// 一次 AX 可用性探针。
    private static func probe() -> (usable: Bool, error: AXError) {
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            system, kAXFocusedApplicationAttribute as CFString, &value)
        return (error == .success || error == .noValue, error)
    }

    /// 是否真实可用（推荐用它判断，而非 isTrusted）。
    static var isFunctional: Bool { permissionState() == .granted }

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

    /// 打开「系统设置 → 隐私与安全性 → 辅助功能」。
    static func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
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
