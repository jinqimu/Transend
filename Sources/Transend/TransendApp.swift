import SwiftUI
import AppKit
import Combine

@main
enum TransendMain {
    /// 手动驱动 AppKit 生命周期，不使用 SwiftUI App/Scene。
    ///
    /// 原因：SwiftUI 的 `Settings { EmptyView() }` 占位场景会在启动时自动弹出一个
    /// 空的 “Transend Settings” 窗口；而菜单栏应用只需 AppDelegate 手动管理
    /// NSStatusItem/NSPopover，这里直接 `NSApplication.run()` 从根上避免该窗口。
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate() // 强引用存活至 run() 结束（app.delegate 为弱引用）
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.mainMenu = makeMainMenu() // 提供编辑菜单，使弹窗/设置里的 ⌘C/⌘V/⌘A 可用
        app.run()
    }

    /// 最小主菜单：仅「编辑」菜单，用于让文本输入/选择支持标准快捷键。
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出 Transend",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: Selector(("cut:")), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: Selector(("copy:")), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: Selector(("paste:")), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: Selector(("selectAll:")), keyEquivalent: "a")
        editItem.submenu = editMenu
        return main
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
    /// 弹窗锚点窗口（见 `popoverAnchor()`）
    private var anchorWindow: NSWindow?
    /// 每次 `showPopover` 递增，用于作废上一次未完成的「等激活再弹」任务
    private var showGeneration = 0

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
        state.refreshAccessibilityIssue() // 打开弹窗时刷新辅助功能状态（可能刚去系统设置授权）
        if state.autoClearInput && !keepInput {
            state.input = ""
            state.output = ""
        }
        guard popover != nil else { return }
        NSApp.activate(ignoringOtherApps: true)
        showGeneration += 1
        presentPopover(generation: showGeneration, attempt: 0)
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

    /// 等应用真正激活后再显示弹窗。
    ///
    /// 前台 App 全屏时，`NSApp.activate` 后系统需要几十毫秒才把激活交给我们；而 `.transient`
    /// 弹窗在应用未激活时会自行关闭（表现为"闪一下就不见了"）。这里最多等约 0.6s 兜底。
    private func presentPopover(generation: Int, attempt: Int) {
        guard generation == showGeneration else { return }
        if !NSApp.isActive && attempt < 12 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.presentPopover(generation: generation, attempt: attempt + 1)
            }
            return
        }
        guard let popover, let anchor = popoverAnchor() else { return }
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        axLog("showPopover: shown attempt=\(attempt) active=\(NSApp.isActive)")
    }

    /// 弹窗锚点：一个 1x1 的透明窗口，放在状态图标正下方。
    ///
    /// 不能直接把 popover 锚定在 `NSStatusItem` 的按钮上：全屏 App 前台时，菜单栏属于另一个
    /// （自动隐藏的）窗口/空间，锚定它显示的弹窗会让 macOS 在 ~0.1s 后撤销本应用的激活
    /// （`_handleDeactivateEvent`），`.transient` 弹窗随即自关。改为锚定自己创建的、
    /// 可加入所有空间（含全屏空间）的透明窗口后，激活不会被撤销，弹窗能正常停留。
    private func popoverAnchor() -> NSView? {
        guard let button = statusItem?.button, let buttonWindow = button.window else { return nil }
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = NSScreen.screens.first {
            $0.frame.contains(NSPoint(x: buttonRect.midX, y: buttonRect.midY))
        } ?? NSScreen.main
        var origin = NSPoint(x: buttonRect.midX, y: buttonRect.minY)
        if let screen { // 菜单栏自动隐藏时状态栏窗口可能在屏幕外，把锚点夹回屏内
            origin.x = min(max(origin.x, screen.frame.minX + 1), screen.frame.maxX - 1)
            origin.y = min(max(origin.y, screen.frame.minY + 1), screen.frame.maxY - 1)
        }
        let frame = NSRect(origin: origin, size: NSSize(width: 1, height: 1))

        let anchorWindow: NSWindow
        if let existing = self.anchorWindow {
            anchorWindow = existing
        } else {
            anchorWindow = NSWindow(contentRect: frame, styleMask: .borderless,
                                    backing: .buffered, defer: false)
            anchorWindow.isOpaque = false
            anchorWindow.backgroundColor = .clear
            anchorWindow.hasShadow = false
            anchorWindow.level = .statusBar
            anchorWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            anchorWindow.ignoresMouseEvents = true
            anchorWindow.isReleasedWhenClosed = false
            self.anchorWindow = anchorWindow
        }
        anchorWindow.setFrame(frame, display: false)
        anchorWindow.orderFrontRegardless()
        return anchorWindow.contentView
    }

    func closePopover() {
        popover?.performClose(nil)
    }

    var isShown: Bool { popover?.isShown ?? false }

    /// 光标聚焦输入框（输入框为 NSTextView 支撑的可编辑多行编辑器）
    func focusInput() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard let popover = self.popover, popover.isShown,
                  let content = popover.contentViewController?.view else { return }
            if let input = Self.firstTextInput(in: content) {
                input.window?.makeFirstResponder(input)
            }
        }
    }

    /// 找到第一个可编辑文本输入（NSTextView 优先，兼容 NSTextField）。
    private static func firstTextInput(in view: NSView) -> NSView? {
        if let tv = view as? NSTextView, tv.isEditable { return tv }
        if let tf = view as? NSTextField { return tf }
        for sub in view.subviews {
            if let found = firstTextInput(in: sub) { return found }
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

    // MARK: - 防止空的 “Transend Settings” 幻影窗口
    //
    // 历史原因：App 曾用 `Settings { EmptyView() }` 作为占位场景。当它成为唯一场景时，
    // macOS 启动/重新激活会走 “open untitled window” 路径，把它渲染成一个空窗口。
    // 现已改为纯 AppKit 生命周期（无 SwiftUI 场景）；以下两道保险进一步杜绝：
    //   - 拒绝“打开无标题窗口”（启动/重开时）
    //   - 关闭应用状态恢复（避免旧的占位窗口从 savedState 被恢复）
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationShouldRestoreApplicationState(_ coder: NSCoder) -> Bool { false }
    func applicationShouldSaveApplicationState(_ coder: NSCoder) -> Bool { false }

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