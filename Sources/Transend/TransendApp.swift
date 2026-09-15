import SwiftUI
import AppKit
import Combine

@main
struct TransendApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // 占位 scene：菜单栏入口由 AppDelegate 手动创建 NSStatusItem + NSPopover。
        // 不用 SwiftUI MenuBarExtra 的原因：其 popover 无法程序化弹出，
        // 快捷翻译热键需要"和点击菜单栏一样"在右上角弹出，必须手动管理。
        // Settings 场景不会自动创建窗口，仅作占位（LSUIElement 应用不使用系统设置面板）。
        Settings { EmptyView() }
    }
}

/// 菜单栏控制器：NSStatusItem（圆圈 T 图标）+ NSPopover（复用 PopoverView 内容）。
/// 点击菜单栏 / 全局热键 → 同一个 popover 在菜单栏右下方弹出，行为完全一致。
@MainActor
final class MenuBarController {
    static let shared = MenuBarController()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var iconSink: AnyCancellable?

    private init() {}

    func setup() {
        let state = AppState.shared

        let vc = NSHostingController(rootView: PopoverView().environmentObject(state))
        let popover = NSPopover()
        popover.contentViewController = vc
        popover.behavior = .transient // 点击外部/Esc 自动关闭（与菜单栏弹窗一致）
        popover.animates = true
        self.popover = popover

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = state.menuIcon
        item.button?.action = #selector(handleStatusItemClick)
        item.button?.target = self
        statusItem = item

        // 图标随引擎/下载状态变色
        iconSink = Publishers.CombineLatest(state.engine.$state, state.downloader.$isDownloading)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.statusItem?.button?.image = AppState.shared.menuIcon
            }
    }

    /// 弹出菜单栏弹窗（快捷键与点击菜单栏共用）。
    /// - Parameter keepInput: true 表示热键已带入待翻译文本（跳过"再次进入清空"并自动翻译）。
    func showPopover(keepInput: Bool = false) {
        let state = AppState.shared
        if state.autoClearInput && !keepInput {
            state.input = ""
        }
        guard let popover, let button = statusItem?.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if keepInput {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                if AppState.shared.engine.isRunning {
                    AppState.shared.translate()
                }
            }
        } else {
            focusInput()
        }
    }

    func closePopover() {
        popover?.performClose(nil)
    }

    var isShown: Bool { popover?.isShown ?? false }

    /// 光标聚焦输入框（SwiftUI TextField 底层即 NSTextField）
    func focusInput() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard let popover = self.popover, popover.isShown,
                  let content = popover.contentViewController?.view else { return }
            if let tf = Self.firstTextField(in: content) {
                tf.window?.makeFirstResponder(tf)
            }
        }
    }

    private static func firstTextField(in view: NSView) -> NSTextField? {
        if let tf = view as? NSTextField { return tf }
        for sub in view.subviews {
            if let found = firstTextField(in: sub) { return found }
        }
        return nil
    }

    @objc private func handleStatusItemClick() {
        if isShown {
            closePopover()
        } else {
            showPopover()
        }
    }
}

/// 设置窗口：手动创建 NSWindow 承载 SettingsView。
/// 菜单栏应用（LSUIElement）的 SwiftUI Settings scene 无法可靠获得焦点，
/// 这里临时切换 .regular 激活策略让窗口置前，关闭后恢复纯菜单栏状态。
@MainActor
enum SettingsWindow {
    fileprivate static var window: NSWindow?

    static func show() {
        if let w = window {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let vc = NSHostingController(
            rootView: SettingsView().environmentObject(AppState.shared))
        let w = NSWindow(contentViewController: vc)
        w.title = "设置"
        w.setContentSize(NSSize(width: 460, height: 660)) // 含引擎/应用两组更新检查与进度，加高防裁剪
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.isReleasedWhenClosed = false
        w.center()
        w.delegate = SettingsWindowDelegate.shared
        window = w
        NSApp.setActivationPolicy(.regular) // 临时显示 Dock 图标以获得窗口焦点
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class SettingsWindowDelegate: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowDelegate()

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === SettingsWindow.window else { return }
        SettingsWindow.window = nil
        restoreAccessoryIfNoWindows()
    }
}

/// 帮助窗口：与设置窗口同一套手动 NSWindow 模式。
@MainActor
enum HelpWindow {
    fileprivate static var window: NSWindow?

    static func show() {
        if let w = window {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let vc = NSHostingController(rootView: HelpView())
        let w = NSWindow(contentViewController: vc)
        w.title = "帮助"
        w.setContentSize(NSSize(width: 540, height: 620))
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        w.delegate = HelpWindowDelegate.shared
        window = w
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class HelpWindowDelegate: NSObject, NSWindowDelegate {
    static let shared = HelpWindowDelegate()

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === HelpWindow.window else { return }
        HelpWindow.window = nil
        restoreAccessoryIfNoWindows()
    }
}

/// 版本记录窗口：展示历史变更。
@MainActor
enum ChangelogWindow {
    fileprivate static var window: NSWindow?

    static func show() {
        if let w = window {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let vc = NSHostingController(rootView: ChangelogView())
        let w = NSWindow(contentViewController: vc)
        w.title = "版本记录"
        w.setContentSize(NSSize(width: 480, height: 560))
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        w.delegate = ChangelogWindowDelegate.shared
        window = w
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class ChangelogWindowDelegate: NSObject, NSWindowDelegate {
    static let shared = ChangelogWindowDelegate()

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === ChangelogWindow.window else { return }
        ChangelogWindow.window = nil
        restoreAccessoryIfNoWindows()
    }
}

/// 设置 / 帮助 / 版本记录 窗口全部关闭后，恢复纯菜单栏应用状态。
@MainActor
func restoreAccessoryIfNoWindows() {
    if SettingsWindow.window == nil && HelpWindow.window == nil && ChangelogWindow.window == nil {
        NSApp.setActivationPolicy(.accessory)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppPaths.migrateIfNeeded() // 旧版（HyMT2）数据目录迁移，避免模型重新下载
        AppState.shared.launch()
        MenuBarController.shared.setup()

        // 开发调试：HYMT2_QUICK_TEXT=xxx 启动 3s 后模拟"刚复制"触发快捷翻译
        if let quickText = ProcessInfo.processInfo.environment["HYMT2_QUICK_TEXT"] {
            for delay in [2.5, 3.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    AppState.shared.input = quickText
                    MenuBarController.shared.showPopover(keepInput: true)
                }
            }
        }
        // 开发调试：HYMT2_OPEN_SETTINGS=1 启动时自动打开设置窗口
        if ProcessInfo.processInfo.environment["HYMT2_OPEN_SETTINGS"] == "1" {
            for delay in [1.0, 2.0, 3.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    SettingsWindow.show()
                }
            }
        }
        // 开发调试：HYMT2_OPEN_HELP=1 启动时自动打开帮助窗口
        if ProcessInfo.processInfo.environment["HYMT2_OPEN_HELP"] == "1" {
            for delay in [1.0, 2.0, 3.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    HelpWindow.show()
                }
            }
        }
        // 开发调试：HYMT2_OPEN_CHANGELOG=1 启动时自动打开版本记录窗口
        if ProcessInfo.processInfo.environment["HYMT2_OPEN_CHANGELOG"] == "1" {
            for delay in [1.0, 2.0, 3.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    ChangelogWindow.show()
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.shutdown()
    }
}