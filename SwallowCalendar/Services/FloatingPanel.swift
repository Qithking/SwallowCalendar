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
}

class FloatingPanel<Content: View>: NSPanel, NSWindowDelegate {
    var isPresented: Bool = false
    var statusBarButton: NSStatusBarButton?
    let onClose: () -> Void
    
    override var isMovable: Bool {
        get { true }
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
        isMovableByWindowBackground = false
        isMovable = false
        hidesOnDeactivate = false
        backgroundColor = NSColor.clear
        titlebarSeparatorStyle = .none
        
        // 启用半透明效果
        isOpaque = false
        hasShadow = true
        
        // 添加圆角和阴影效果（类似 MenuBarExtra）
        // 圆角 = Popup.cornerRadius + Popup.horizontalPadding
        // macOS 26+: 7 + 5 = 12pt, 旧版本: 4 + 5 = 9pt
        contentView?.wantsLayer = true
        contentView?.layer?.cornerRadius = Popup.cornerRadius + Popup.horizontalPadding
        contentView?.layer?.masksToBounds = false
        
        // 添加阴影
        contentView?.layer?.shadowColor = NSColor.black.cgColor
        contentView?.layer?.shadowOffset = NSSize(width: 0, height: -2)
        contentView?.layer?.shadowOpacity = 0.3
        contentView?.layer?.shadowRadius = 10
        
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
            // 获取按钮在屏幕坐标系中的位置
            // NSStatusBarButton 的 convert(to: nil) 返回的是相对于其父窗口的坐标
            // 我们需要将其转换为屏幕坐标
            let buttonFrameInWindow = button.convert(button.bounds, to: nil)
            
            // 获取按钮所在窗口
            guard let buttonWindow = button.window else { return }
            
            // 将按钮坐标转换为屏幕坐标
            let buttonFrameInScreen = buttonWindow.convertToScreen(buttonFrameInWindow)
            
            // 窗口应该显示在按钮下方，左对齐
            var originX = buttonFrameInScreen.minX
            var originY = buttonFrameInScreen.minY - frame.height - 5 // 5px 间距
            
            // 获取屏幕可见区域
            let screen = buttonWindow.screen ?? NSScreen.main
            guard let screenFrame = screen?.visibleFrame else { return }
            
            // 确保窗口不超出屏幕右边界
            if originX + frame.width > screenFrame.maxX {
                originX = screenFrame.maxX - frame.width - 10
            }
            
            // 确保窗口不超出屏幕左边界
            if originX < screenFrame.minX {
                originX = screenFrame.minX + 10
            }
            
            // 确保窗口不超出屏幕底部
            if originY < screenFrame.minY {
                originY = screenFrame.minY + 10
            }
            
            setFrameOrigin(NSPoint(x: originX, y: originY))
        } else {
            // 居中显示
            if let screen = NSScreen.main {
                let screenFrame = screen.visibleFrame
                let x = screenFrame.midX - frame.width / 2
                let y = screenFrame.midY - frame.height / 2
                setFrameOrigin(NSPoint(x: x, y: y))
            }
        }
        
        orderFrontRegardless()
        
        // 先激活应用，再让窗口成为关键窗口
        NSApp.activate(ignoringOtherApps: true)
        
        makeKeyAndOrderFront(nil)
        isPresented = true
        
        // 高亮状态栏按钮
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
    
    func windowDidResignKey(_ notification: Notification) {
        // 窗口失去焦点时，如果未固定则关闭
        if isPresented && !AppSettings.shared.isWindowPinned {
            close()
        }
    }
    
    override func resignKey() {
        super.resignKey()
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
