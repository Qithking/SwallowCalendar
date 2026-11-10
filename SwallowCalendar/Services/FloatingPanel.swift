//
//  FloatingPanel.swift
//  SwallowCalendar
//
//  可缩放浮动面板
import SwiftUI
import AppKit

// MARK: - Popup 配置
enum Popup {
    // 内边距
    static let horizontalPadding: CGFloat = 5
    
    // 圆角半径（根据 macOS 版本动态调整）
    static let cornerRadius: CGFloat = if #available(macOS 26.0, *) {
        7
    } else {
        4
    }
    
    // 总圆角半径（contentView 使用的圆角）
    static var totalCornerRadius: CGFloat {
        return cornerRadius + horizontalPadding
    }
}

// MARK: - Toggle 回声窗口

/// R-1（fix: statusbar-toggle-race）：主面板 toggle 的 resignKey 回声窗口。
/// 点击状态栏图标使 key 面板先失 key 关闭，button action 晚 30-56ms 到达后
/// 按 presented=N 又 open——同一次点击只应翻转一次状态，窗口内第二次
/// 翻转视为回声忽略。窗口覆盖取证观测最大间隔 56ms，取 150ms 留余量
enum PanelToggle {
    static let resignKeyEchoWindow: TimeInterval = 0.15
}

class FloatingPanel<Content: View>: NSPanel, NSWindowDelegate {
    var isPresented: Bool = false
    var statusBarButton: NSStatusBarButton?
    let onClose: () -> Void
    /// 保存内容视图构建闭包，close 销毁层级后 open 重建用
    private let contentBuilder: () -> Content

    /// R-1（fix: statusbar-toggle-race）：自动关闭（resignKey 链或 global 兜底链）
    /// 的发生时刻。点击状态栏图标会使 key 面板先失 key（探针实证：keyWin=nil 且
    /// action 晚 30-56ms 到达），resignKey 先 close 后，action 的 toggle 按
    /// presented=N 又 open——一轮点击经历「关了又开」，表现为无法关闭。激活失败态
    /// 下点图标同理：mouseDown 走 global 兜底先 close，action 晚到重开。同一次
    /// 点击只应翻转一次状态，窗口内第二次翻转视为回声忽略。窗口覆盖取证观测最大
    /// 间隔 56ms，取 150ms 留余量
    private var lastAutoCloseAt: Date?

    private var pinObserver: NSObjectProtocol?
    private var deactivateObserver: NSObjectProtocol?

    // fix: click-outside-activation-gap：app 激活失败且面板未成为 key 时
    // （取证：open done active=false isKey=false，Xcode/LLDB 运行下必现），
    // 点击桌面/其他应用不产生 resignKey 与 resignActive，双关闭链沉默。
    // 全局鼠标监听器仅在 app 非 active 时收到事件，恰好覆盖该盲区
    private var globalClickMonitor: Any?

    /// 测试观察用：全局鼠标监听器是否已安装
    var hasGlobalClickMonitor: Bool { globalClickMonitor != nil }

    deinit {
        if let observer = pinObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = deactivateObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
    
    override var isMovable: Bool {
        get { false }
        set {}
    }
    
    init(
        contentRect: NSRect,
        identifier: String = "",
        statusBarButton: NSStatusBarButton? = nil,
        onClose: @escaping () -> Void,
        @ViewBuilder view: @escaping () -> Content
    ) {
        self.onClose = onClose
        self.statusBarButton = statusBarButton
        self.contentBuilder = view
        
        super.init(
            contentRect: contentRect,
            styleMask: [.resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        self.identifier = NSUserInterfaceItemIdentifier(identifier)
        delegate = self
        
        animationBehavior = .none
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.auxiliary, .stationary, .moveToActiveSpace, .fullScreenAuxiliary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false  // 禁止通过拖动背景移动窗口
        hidesOnDeactivate = false
        backgroundColor = NSColor.clear
        titlebarSeparatorStyle = .none
        
        // 启用半透明效果，使毛玻璃效果生效
        isOpaque = false
        hasShadow = true
        
        // 确保窗口背景透明，让VisualEffectView的毛玻璃效果显示
        contentView?.wantsLayer = true
        
        // 设置窗口最小和最大尺寸
        minSize = NSSize(width: 340, height: 600)
        maxSize = NSSize(width: 500, height: 1000)

        // 构建内容视图（NSHostingController 承载，便于 close 时销毁层级）
        installContentView()
        
        // 监听应用失焦通知，未固定时自动关闭窗口
        deactivateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.appDidResignActive()
        }
    }
    
    @objc private func appDidResignActive() {
        if shouldClose() {
            close()
        }
    }
    
    func toggle() {
        if isPresented {
            close()
        } else if let at = lastAutoCloseAt,
                  Date().timeIntervalSince(at) < PanelToggle.resignKeyEchoWindow {
            // 面板刚由自动关闭链（resignKey 或 global 兜底）关掉，忽略 action 回声不重开
            lastAutoCloseAt = nil
        } else {
            open()
        }
    }
    
    /// 构建并安装内容视图（init 与 open 重建共用同一入口）
    private func installContentView() {
        let rootView = contentBuilder()
            .ignoresSafeArea()
        // 用 NSHostingController 承载，close 置空 contentViewController 即可销毁层级；
        // 直接赋值 NSHostingView 时窗口仅 orderOut，无法触发 SwiftUI onDisappear
        let hostingController = NSHostingController(rootView: AnyView(rootView))
        contentViewController = hostingController
        // 关键：设置自动调整大小掩码，使内容跟随窗口尺寸变化
        hostingController.view.autoresizingMask = [.width, .height]
        // 设置 contentView 圆角和阴影
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
        hostingController.view.layer?.cornerRadius = Popup.totalCornerRadius
        hostingController.view.layer?.masksToBounds = true
    }

    func open() {
        // close 时已销毁视图层级，重开前必须重建，否则面板空白
        if contentViewController == nil {
            installContentView()
        }

        // 从 UserDefaults 恢复窗口尺寸
        let savedWidth = UserDefaults.standard.double(forKey: "mainWindowWidth")
        let savedHeight = UserDefaults.standard.double(forKey: "mainWindowHeight")
        
        let width = savedWidth > 340 ? savedWidth : 340
        let height = savedHeight > 600 ? savedHeight : 600
        
        setContentSize(NSSize(width: width, height: height))
        
        // 定位到状态栏图标下方
        if let button = statusBarButton {
            let buttonFrameInWindow = button.convert(button.bounds, to: nil)
            guard let buttonWindow = button.window else { return }
            let buttonFrameInScreen = buttonWindow.convertToScreen(buttonFrameInWindow)
            
            var originX = buttonFrameInScreen.minX
            var originY = buttonFrameInScreen.minY - frame.height - 5
            
            let screen = buttonWindow.screen ?? NSScreen.main
            guard let screenFrame = screen?.visibleFrame else { return }
            
            if originX + frame.width > screenFrame.maxX {
                originX = screenFrame.maxX - frame.width - 10
            }
            if originX < screenFrame.minX {
                originX = screenFrame.minX + 10
            }
            if originY < screenFrame.minY {
                originY = screenFrame.minY + 10
            }
            
            setFrameOrigin(NSPoint(x: originX, y: originY))
        } else {
            if let screen = NSScreen.main {
                let screenFrame = screen.visibleFrame
                let x = screenFrame.midX - frame.width / 2
                let y = screenFrame.midY - frame.height / 2
                setFrameOrigin(NSPoint(x: x, y: y))
            }
        }
        
        orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        isPresented = true
        installGlobalClickMonitor()
        contentView?.needsDisplay = true
        statusBarButton?.isHighlighted = true
    }
    
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        var newSize = frameSize
        newSize.width = max(newSize.width, 340)
        newSize.height = max(newSize.height, 600)
        return newSize
    }
    
    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let size = window.frame.size
        UserDefaults.standard.set(size.width, forKey: "mainWindowWidth")
        UserDefaults.standard.set(size.height, forKey: "mainWindowHeight")
    }
    
    // MARK: - 关闭逻辑（统一处理）

    /// 检查是否应该关闭窗口（未固定且已显示）
    private func shouldClose() -> Bool {
        return isPresented && !AppSettings.shared.isWindowPinned
    }

    /// 全局点击是否应关闭面板：已显示、未固定、且点击点在面板外。
    /// 坐标系与 NSWindow.frame 一致（屏幕坐标，左下原点）
    func shouldCloseOnGlobalClick(at location: NSPoint) -> Bool {
        return shouldClose() && !frame.contains(location)
    }

    /// 全局点击兜底关闭（global monitor 闭包调用）。命中时与 resignKey 链同样
    /// 写入回声时间戳：激活失败态下点击状态栏图标，mouseDown 先走本兜底 close，
    /// button action 的 toggle 晚到，无时间戳会按 presented=false 重开面板
    /// （R-1 同型竞态）
    func closeOnGlobalClick(at location: NSPoint) {
        guard shouldCloseOnGlobalClick(at: location) else { return }
        lastAutoCloseAt = Date()
        close()
    }

    /// 安装全局鼠标按下监听器（open 时调用，幂等）。
    /// global monitor 只在 app 非 active 时收到事件——app active 的点击
    /// 走应用内事件流，仍由 resignKey/resignActive 双链处理，互不重叠
    private func installGlobalClickMonitor() {
        guard globalClickMonitor == nil else { return }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            // monitor 闭包非隔离，由系统保证主线程调用，按项目惯例 assumeIsolated 转入
            MainActor.assumeIsolated {
                guard let self else { return }
                self.closeOnGlobalClick(at: NSEvent.mouseLocation)
            }
        }
    }

    private func removeGlobalClickMonitor() {
        guard let monitor = globalClickMonitor else { return }
        NSEvent.removeMonitor(monitor)
        globalClickMonitor = nil
    }
    
    func windowDidResignKey(_ notification: Notification) {
        // 应用内其他窗口（编辑/设置/提醒弹窗、菜单、Popover）抢走 key 时不关闭面板，
        // 点击其他应用的失焦场景由 deactivateObserver 兜底关闭
        if let newKeyWindow = NSApp.keyWindow, newKeyWindow !== self, NSApp.isActive {
            return
        }
        if shouldClose() {
            // 记录自动关闭时刻，供 toggle 识别同一次状态栏点击的回声
            lastAutoCloseAt = Date()
            close()
        }
    }
    
    override func close() {
        super.close()
        // NSPanel 的 close 仅 orderOut 不销毁层级，显式置空 contentViewController
        // 触发 SwiftUI onDisappear，注销面板内倒计时等定时器，避免隐藏面板后台跑 Timer
        contentViewController = nil
        isPresented = false
        removeGlobalClickMonitor()
        statusBarButton?.isHighlighted = false
        onClose()
    }
    
    override var canBecomeKey: Bool {
        return true
    }
}
