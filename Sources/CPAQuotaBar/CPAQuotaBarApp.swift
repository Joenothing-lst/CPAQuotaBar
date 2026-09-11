import AppKit
import SwiftUI

private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@main
enum CPAQuotaBarApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = AppModel()
    private var statusItem: NSStatusItem?
    private var statusHost: NSHostingView<AnyView>?
    private let popover = NSPopover()
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?

    private static let statusItemWidth: CGFloat = 76

    // 专属锚点窗口：防止在 macOS 全屏应用模式下，系统菜单栏自动隐藏收起导致 statusItem.button 坐标失效脱离屏幕，
    // 进而使 NSPopover 在动态改变 contentSize 时被系统重定位到屏幕左上角 (0, 0)。
    private lazy var anchorWindow: NSWindow = {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.statusItemWidth, height: 24),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = NSView(frame: NSRect(x: 0, y: 0, width: Self.statusItemWidth, height: 24))
        window.contentView = view
        return window
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        configureStatusItem()
        configurePopover()
        if CommandLine.arguments.contains("--show-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                NSApp.activate(ignoringOtherApps: true)
                self?.togglePopover(nil)
            }
        }
    }

    /// 构建系统主菜单（Edit 菜单），彻底解决 .accessory 菜单栏应用中输入框无法使用 ⌘C / ⌘V / ⌘X / ⌘A / ⌘Z 快捷键的问题。
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // 1. App 自身菜单
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 CPA Quota Bar", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "退出 CPA Quota Bar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // 2. Edit 菜单（关键：向系统响应链注册剪切、复制、粘贴、全选与撤销快捷键）
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")

        let undoItem = NSMenuItem(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]

        let cutItem = NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        let copyItem = NSMenuItem(title: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        let pasteItem = NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let selectAllItem = NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        editMenu.addItem(undoItem)
        editMenu.addItem(redoItem)
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(cutItem)
        editMenu.addItem(copyItem)
        editMenu.addItem(pasteItem)
        editMenu.addItem(selectAllItem)

        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: Self.statusItemWidth)
        guard let button = item.button else { return }
        button.title = ""
        button.image = nil
        button.toolTip = "CPA 额度"
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp])

        let host = PassthroughHostingView(
            rootView: AnyView(
                StatusBarLabel(model: model)
                    .frame(width: Self.statusItemWidth - 2, height: 24)
                    .allowsHitTesting(false)
            )
        )
        host.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 1),
            host.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -1),
            host.topAnchor.constraint(equalTo: button.topAnchor),
            host.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])

        statusHost = host
        statusItem = item
    }

    private func configurePopover() {
        popover.behavior = .transient
        // 关闭 NSPopover 默认老式 30fps 定时器动画，由 CoreAnimation 和 SwiftUI 统一驱动高帧率物理弹簧动画
        popover.animates = false
        popover.delegate = self
        popover.contentSize = NSSize(width: 430, height: 335)
        popover.contentViewController = NSHostingController(
            rootView: RootView(model: model) { [weak self] height in
                self?.resizePopover(to: height)
            }
        )
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            guard let buttonWindow = button.window else { return }
            let rectInWindow = button.convert(button.bounds, to: nil)
            let screenRect = buttonWindow.convertToScreen(rectInWindow)
            anchorWindow.setFrame(screenRect, display: false)
            anchorWindow.orderBack(nil)

            guard let anchorView = anchorWindow.contentView else { return }
            popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
            if let window = popover.contentViewController?.view.window {
                window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                window.makeKey()
            }
            NSApp.activate(ignoringOtherApps: true)
            startEventMonitoring()
        }
    }

    private func resizePopover(to height: CGFloat) {
        let screen = anchorWindow.screen ?? statusItem?.button?.window?.screen ?? NSScreen.main
        let screenHeight = screen?.visibleFrame.height ?? 800
        let maxHeight = max(300, screenHeight - 60)
        let clampedHeight = min(height, maxHeight)
        let targetSize = NSSize(width: 430, height: clampedHeight)
        guard popover.contentSize != targetSize else { return }

        guard let popoverWindow = popover.contentViewController?.view.window, popover.isShown else {
            popover.contentSize = targetSize
            return
        }

        let currentFrame = popoverWindow.frame
        let margin = max(0, popoverWindow.frame.height - popover.contentSize.height)
        let targetWindowHeight = clampedHeight + margin
        let targetFrame = NSRect(
            x: currentFrame.origin.x,
            y: currentFrame.maxY - targetWindowHeight,
            width: currentFrame.width,
            height: targetWindowHeight
        )

        // 窗口向下平滑延伸/收缩，带有轻微的物理加速减速（easeInEaseOut），无任何弹跳
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.26
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            popoverWindow.animator().setFrame(targetFrame, display: true)
        }, completionHandler: { [weak self] in
            guard let self, self.popover.isShown else { return }
            self.popover.contentSize = targetSize
        })
    }

    private func startEventMonitoring() {
        stopEventMonitoring()

        // 全局监听：点击空白桌面、其他 App 窗口或全屏空白区域，100% 可靠自动收起浮窗
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.popover.isShown else { return }
                self.popover.performClose(nil)
            }
        }

        // 应用内监听：点击本应用外部空白区域（非浮窗自身内部）时收起
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            if let popWindow = self.popover.contentViewController?.view.window {
                if event.window == popWindow {
                    return event
                }
                // 保护浮窗内的子窗口与右键上下文菜单（点击落在浮窗屏幕矩形内则不关闭）
                let mouseLocation = NSEvent.mouseLocation
                if popWindow.frame.contains(mouseLocation) {
                    return event
                }
            }
            if let btnWindow = self.statusItem?.button?.window, event.window == btnWindow {
                return event
            }
            DispatchQueue.main.async {
                self.popover.performClose(nil)
            }
            return event
        }
    }

    private func stopEventMonitoring() {
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
    }

    func popoverDidShow(_ notification: Notification) {
        startEventMonitoring()
        model.setPanelVisible(true)
    }

    func popoverDidClose(_ notification: Notification) {
        stopEventMonitoring()
        anchorWindow.orderOut(nil)
        model.setPanelVisible(false)
    }
}
