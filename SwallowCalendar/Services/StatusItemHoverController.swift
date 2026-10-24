//
//  StatusItemHoverController.swift
//  SwallowCalendar
//
//  状态栏图标 hover 弹层控制器（plan step 1）：
//  - NSTrackingArea 挂在系统 statusItem.button 上（不替换 button，点击链路零风险）
//  - owner 继承 NSResponder 才能收到 mouseEntered/mouseExited 路由
//  - mouseEntered 延迟 300ms 弹出，fire 时二次校验鼠标仍在 button 内
//    （跟踪失效时退化为"不弹"而非"误弹"）
//  - mouseExited 延迟 300ms 检查鼠标是否已移入弹层，避免图标→弹层间隙误关
//

import AppKit
import SwiftUI

@MainActor
final class StatusItemHoverController: NSResponder {

    /// 延迟弹出/延迟关闭检查的时长（spec 用户决策：延迟弹出+移开即关）
    private static let hoverDelay: TimeInterval = 0.3

    /// 弹层内容构造器（由装配方注入，便于视图回调接线）
    var contentProvider: (() -> NSViewController)?

    /// 点击弹层条目时的回调（关弹层 + 打开主面板）
    private var onOpenMainPanel: (() -> Void)?

    /// 弹出抑制器（由装配方注入）：返回 true 时挂起弹出——
    /// 主面板与弹层互斥（用户需求：打开主界面时不显示 pop 弹出框）
    var isSuppressed: (() -> Bool)?

    private let popover = NSPopover()
    private weak var button: NSButton?
    private var openTimer: Timer?
    private var closeCheckTimer: Timer?

    override init() {
        super.init()
        // transient：点击弹层外部自动关闭（AC-3 的兜底）
        popover.behavior = .transient
        popover.animates = false
    }

    required init?(coder: NSCoder) {
        fatalError("不支持从 NSCoder 初始化")
    }

    /// 绑定状态栏 button 并安装跟踪区域（重复调用以最后一次为准）
    func bind(button: NSButton, onOpenMainPanel: @escaping () -> Void) {
        self.button = button
        self.onOpenMainPanel = onOpenMainPanel
        // .inVisibleRect：rect 动态等于 visibleRect，随 button 宽度（徽标切换）自动同步
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        button.addTrackingArea(area)
    }

    // MARK: - 跟踪事件（owner 为 self，由 AppKit 路由）

    override func mouseEntered(with event: NSEvent) {
        openTimer?.invalidate()
        openTimer = Timer.scheduledTimer(
            timeInterval: Self.hoverDelay,
            target: self,
            selector: #selector(openTimerFired),
            userInfo: nil,
            repeats: false
        )
    }

    override func mouseExited(with event: NSEvent) {
        // 移出图标即取消挂起的弹出（<300ms 划过不弹，AC-2）
        openTimer?.invalidate()
        openTimer = nil
        // 延迟检查：鼠标若已移入弹层则保持（AC-3，图标→弹层间隙）
        closeCheckTimer?.invalidate()
        closeCheckTimer = Timer.scheduledTimer(
            timeInterval: Self.hoverDelay,
            target: self,
            selector: #selector(closeCheckTimerFired),
            userInfo: nil,
            repeats: false
        )
    }

    // MARK: - 定时器触发（target-action：主 runloop 线程调用，无并发闭包标注问题）

    @objc private func openTimerFired() {
        openTimer = nil
        guard let contentProvider, let button, !popover.isShown else { return }
        // 互斥抑制：主面板可见时不弹（弹层与主界面不能同时显示）
        guard isSuppressed?() != true else { return }
        // 跟踪失效兜底：fire 时二次校验鼠标仍在 button 的屏幕 frame 内
        guard let window = button.window else { return }
        let frameInScreen = window.convertToScreen(button.convert(button.bounds, to: nil))
        guard frameInScreen.contains(NSEvent.mouseLocation) else { return }
        popover.contentViewController = contentProvider()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    @objc private func closeCheckTimerFired() {
        closeCheckTimer = nil
        guard popover.isShown,
              let window = popover.contentViewController?.view.window else { return }
        // 鼠标已不在弹层窗口内才关闭
        if !window.frame.contains(NSEvent.mouseLocation) {
            closePopover()
        }
    }

    // MARK: - 公开操作

    /// 弹层条目点击：关弹层并打开主面板（AC-6）
    func openMainPanel() {
        closePopover()
        onOpenMainPanel?()
    }

    /// 关闭弹层并取消挂起定时器（点击图标前调用，避免弹层与主面板叠加）
    func closePopover() {
        openTimer?.invalidate()
        openTimer = nil
        closeCheckTimer?.invalidate()
        closeCheckTimer = nil
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    // MARK: - 私有辅助
}
