//
//  DesktopTodoPanelManager.swift
//  SwallowCalendar
//
//  桌面常驻待办面板窗口管理（spec: desktop-todo-panel，plan Option A）
//  nonactivating NSPanel + .normal-1 层级 + 跨空间常驻：可点击不激活应用、不抢焦点
//

import SwiftUI
import AppKit
import SwiftData
import os

@MainActor
final class DesktopTodoPanelManager {
    static let shared = DesktopTodoPanelManager()

    /// frame 持久化 key（CGRect JSON，含位置与尺寸）；nonisolated：String 常量，供 nonisolated persist 访问
    private nonisolated static let frameKey = "desktopPanelFrame"

    /// 置顶状态（会话内记忆：面板对象不销毁即保留；不持久化，重启后回落未置顶）
    private(set) var isPinned = false

    private var container: ModelContainer?
    private var panel: NSPanel?
    private var moveObserver: NSObjectProtocol?
    private var resizeObserver: NSObjectProtocol?

    private init() {}

    /// 面板层级纯函数（测试覆盖）：
    /// - 未置顶：.normal - 1——低于所有普通应用窗口，但明确高于桌面生态全部层
    ///   （壁纸 desktopWindow / 桌面图标 desktopIcon）：desktopWindow+1 实测仍被
    ///   macOS 26 桌面图标窗口拦截点击，事件到不了窗口（bug: desktop-panel-picker-not-clickable 四轮取证）
    /// - 置顶：.floating——高于所有普通应用窗口，不被其他应用遮挡
    static func level(isPinned: Bool) -> NSWindow.Level {
        isPinned ? .floating : NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
    }

    /// 置顶开关：切换面板层级（level 赋值即时生效，无需重新 orderFront）
    func setPinned(_ pinned: Bool) {
        isPinned = pinned
        panel?.level = Self.level(isPinned: pinned)
    }

    /// AppDelegate 启动时注入共享容器（避免 Manager → AppDelegate 反向依赖）
    func configure(with container: ModelContainer) {
        self.container = container
    }

    /// 开关驱动的显隐同步（幂等；AppSettings.didSet 与 AppDelegate 启动补偿共用）
    func syncVisibility() {
        if AppSettings.shared.desktopTodoPanelEnabled {
            guard ensurePanel() else { return }
            // orderFrontRegardless 不 makeKey：显示但不抢焦点
            panel?.orderFrontRegardless()
        } else {
            panel?.orderOut(nil)
        }
    }

    // MARK: - 窗口创建

    /// 惰性创建面板；容器未注入（didSet 早于 AppDelegate 装配）时跳过，由启动补偿兜底
    private func ensurePanel() -> Bool {
        if panel != nil { return true }
        guard let container else {
            AppLogger.settings.error("桌面面板已开启但 ModelContainer 未注入，等待启动补偿")
            return false
        }

        let settings = AppSettings.shared
        let rootView = DesktopTodoPanelView()
            .environment(settings)
            .modelContainer(container)
            .ignoresSafeArea()

        let panel = DesktopPanel(
            contentRect: defaultFrame(),
            styleMask: [.nonactivatingPanel, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "桌面待办"
        panel.contentView = NSHostingView(rootView: rootView)
        // .normal - 1：低于所有普通应用窗口、高于桌面生态全部层（详见 level(isPinned:) 注释）
        panel.level = Self.level(isPinned: isPinned)
        // 跨空间常驻 + 不参与 Cmd+` 窗口循环
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 240, height: 200)

        // 透明背景让内容视图毛玻璃生效（FloatingPanel 同款配置）
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        if let contentView = panel.contentView {
            contentView.wantsLayer = true
            contentView.layer?.backgroundColor = NSColor.clear.cgColor
            contentView.layer?.cornerRadius = Popup.totalCornerRadius
            contentView.layer?.masksToBounds = true
        }

        // 恢复持久化位置尺寸，出屏钳制（外接屏拔出场景回落默认位置）
        panel.setFrame(restoreFrame(fallback: panel.frame), display: true)

        // 拖动/缩放结束持久化 frame（UserDefaults 线程安全，persist 无需隔离）
        let center = NotificationCenter.default
        moveObserver = center.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { note in
            guard let win = note.object as? NSWindow else { return }
            Self.persist(win.frame)
        }
        resizeObserver = center.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: panel, queue: .main) { note in
            guard let win = note.object as? NSWindow else { return }
            Self.persist(win.frame)
        }

        self.panel = panel
        return true
    }

    /// 默认出现在主屏幕右上区域（visibleFrame 已避开状态栏与 Dock）
    private func defaultFrame() -> NSRect {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 300, height: 420)
        return NSRect(
            x: visible.maxX - size.width - 24,
            y: visible.maxY - size.height - 24,
            width: size.width,
            height: size.height
        )
    }

    /// 读取持久化 frame；与任一屏幕可见帧无交集（完全出屏）时回落默认位置
    private func restoreFrame(fallback: NSRect) -> NSRect {
        guard let data = UserDefaults.standard.data(forKey: Self.frameKey),
              let saved = try? JSONDecoder().decode(CGRect.self, from: data) else {
            return fallback
        }
        let onSomeScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(saved) }
        return onSomeScreen ? saved : fallback
    }

    private nonisolated static func persist(_ frame: NSRect) {
        if let data = try? JSONEncoder().encode(frame) {
            UserDefaults.standard.set(data, forKey: frameKey)
        }
    }

    deinit {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
    }
}

/// canBecomeKey=true：nonactivating styleMask 保证点击不激活应用、不抢焦点（不激活 app），
/// 但窗口需可成为 key，SwiftUI Picker 等桥接控件的 action 响应链才通
/// （真机复现：false 时 Picker 点击失效，bug: desktop-panel-picker-not-clickable）
final class DesktopPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
