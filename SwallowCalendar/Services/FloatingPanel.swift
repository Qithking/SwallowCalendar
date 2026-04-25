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
    static let verticalPadding: CGFloat = 5
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

class FloatingPanel<Content: View>: NSPanel, NSWindowDelegate {
    var isPresented: Bool = false
    var statusBarButton: NSStatusBarButton?
    let onClose: () -> Void
    
    private var pinObserver: NSObjectProtocol?
    private var deactivateObserver: NSObjectProtocol?
    
    deinit {
        if let observer = pinObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = deactivateObserver {
            NotificationCenter.default.removeObserver(observer)
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
        
        // 设置内容视图
        let rootView = view()
            .ignoresSafeArea()
        
        contentView = NSHostingView(
            rootView: AnyView(rootView)
        )
        
        // 关键：设置自动调整大小掩码，使内容跟随窗口尺寸变化
        contentView?.autoresizingMask = [.width, .height]
        
        // 设置 contentView 圆角和阴影
        contentView?.wantsLayer = true
        contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        contentView?.layer?.cornerRadius = Popup.totalCornerRadius
        contentView?.layer?.masksToBounds = true
        
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
        } else {
            open()
        }
    }
    
    func open() {
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
        let isPinned = UserDefaults.standard.bool(forKey: "isWindowPinned")
        return isPresented && !isPinned
    }
    
    func windowDidResignKey(_ notification: Notification) {
        if shouldClose() {
            close()
        }
    }
    
    override func close() {
        super.close()
        isPresented = false
        statusBarButton?.isHighlighted = false
        onClose()
    }
    
    override var canBecomeKey: Bool {
        return true
    }
}
