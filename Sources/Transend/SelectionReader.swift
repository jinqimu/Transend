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
    /// - stale：曾授权，但授权记录与当前二进制不匹配（adhoc 更新后常见）
    /// - needsRestart：TCC 已信任，但当前进程的 AX 连接未生效，需重启 App
    enum PermissionState: Equatable {
        case granted
        case denied
        case stale
        case needsRestart
    }

    /// 实时查询 TCC 授权状态。
    ///
    /// 必须用 `AXIsProcessTrustedWithOptions(nil)` 而非 `AXIsProcessTrusted()`：
    /// 后者返回**进程内缓存值**，用户在系统设置里改授权后不会刷新，
    /// 导致"明明已授权却一直报未授权"。带 options 的版本会实时询问 TCC。
    static var isTrusted: Bool { AXIsProcessTrustedWithOptions(nil) }

    /// 是否真实可用：TCC 已信任 **且** AX API 调用成功。
    ///
    /// 未授权 / 授权失效时 AX 调用返回的错误码并不统一
    /// （实测：未授权返回 -25204 cannotComplete 或 -25208 notImplemented；
    /// 文档中的 -25211 apiDisabled 反而不常见），故任何非 success/noValue 都视为不可用。
    static var isFunctional: Bool {
        guard isTrusted else { return false }
        if probe() { return true }
        Thread.sleep(forTimeInterval: 0.05)
        let ok = probe()
        if !ok { axLog("isFunctional: trusted but API probe failed -> 需重启进程") }
        return ok
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

    // MARK: - 修复 / 重启

    /// 重启自身。授权后当前进程的 AX 连接可能仍是旧的；reset 后也需要新进程才能
    /// 再次弹出系统授权框（`kAXTrustedCheckOptionPrompt` 每个进程只弹一次，旧进程里再调用是空操作）。
    @MainActor
    static func relaunchSelf() {
        let path = Bundle.main.bundleURL.path.replacingOccurrences(of: "'", with: "'\\''")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.6; /usr/bin/open '\(path)'"]
        try? task.run()
        NSApp.terminate(nil)
    }

    /// 「一键修复」：清除失效的 TCC 记录并重启，重启后由新进程弹出系统授权框。
    @MainActor
    static func resetAndRelaunch() {
        resetPermission()
        UserDefaults.standard.set(true, forKey: "axRecoverPending")
        relaunchSelf()
    }

    /// 读取当前前台 App 中选中的文本；无权限 / 无选区 / 选区为空时返回 nil。
    /// 排除本 App 自身；焦点元素没有选区时向下遍历子元素（浏览器 / Electron 常见）。
    static func selectedText() -> String? {
        guard isTrusted else { axLog("selectedText: not trusted"); return nil }
        let system = AXUIElementCreateSystemWide()

        // 排除自身：读取当前焦点 App 的 pid
        if let app = copyElement(system, kAXFocusedApplicationAttribute as CFString),
           let pid = pid(of: app), pid == getpid() {
            axLog("selectedText: focused app is self")
            return nil
        }

        guard let focused = copyElement(system, kAXFocusedUIElementAttribute as CFString) else {
            axLog("selectedText: no focused element")
            return nil
        }
        guard let text = selectedText(from: focused) else {
            axLog("selectedText: no selected text")
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { axLog("selectedText: empty"); return nil }
        axLog("selectedText: got \(trimmed.count) chars")
        return trimmed
    }

    /// 在元素及其子元素中查找 AXSelectedText（广度优先，深度 ≤3、总节点 ≤200，避免大量 AX 调用卡顿）。
    private static func selectedText(from element: AXUIElement) -> String? {
        var queue: [(element: AXUIElement, depth: Int)] = [(element, 0)]
        var visited = 0
        var index = 0
        while index < queue.count, visited < 200 {
            let (el, depth) = queue[index]
            index += 1
            visited += 1
            if let text = copyString(el, kAXSelectedTextAttribute as CFString), !text.isEmpty {
                return text
            }
            guard depth < 3,
                  let children = copyElementArray(el, kAXChildrenAttribute as CFString) else { continue }
            for child in children.prefix(30) {
                queue.append((child, depth + 1))
            }
        }
        return nil
    }

    // MARK: - AX 工具

    private static func copyElement(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private static func copyElementArray(_ element: AXUIElement, _ attribute: CFString) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? [AXUIElement]
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
