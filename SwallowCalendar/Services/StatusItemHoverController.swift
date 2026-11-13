//
//  StatusItemHoverController.swift
//  SwallowCalendar
//
//  状态栏图标 hover 弹层控制器：
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

    /// 弹出抑制器（由装配方注入）：返回 true 时挂起弹出——
    /// 主面板与弹层互斥（用户需求：打开主界面时不显示 pop 弹出框）
    var isSuppressed: (() -> Bool)?

    private let popover = NSPopover()
    private weak var button: NSButton?
    private var openTimer: Timer?
    private var closeCheckTimer: Timer?

    override init() {
        super.init()
        // transient：点击弹层外部自动关闭（跟踪失效时的兜底）
        // fix: popover-click-open-panel——transient 弹层会成为 key window，
        // 关闭时使 app 失活（失去唯一 key 窗口），随后打开的主面板会被失活
        // 自动关闭链误关。改为 applicationDefined：弹层不成为 key，关闭时
        // 不影响 app 激活状态；弹层关闭仍由 hover 移出/点击图标逻辑主动触发
        popover.behavior = .applicationDefined
        popover.animates = false
    }

    required init?(coder: NSCoder) {
        fatalError("不支持从 NSCoder 初始化")
    }

    /// 绑定状态栏 button 并安装跟踪区域（重复调用以最后一次为准）。
    /// 「关弹层 + 开主面板」仅由图标点击（performStatusItemClick）触发，
    /// 弹层条目不可点击唤起主面板（用户需求，守卫测试
    /// StatusPopoverEntryClickGuardTests 把关）
    func bind(button: NSButton) {
        self.button = button
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
        // 移出跟踪源（图标/弹层）即取消挂起的弹出（<300ms 划过不弹）
        openTimer?.invalidate()
        openTimer = nil
        // 延迟检查：鼠标若已移入弹层则保持（图标→弹层间隙），
        // 移出弹层（非经图标路径）则 300ms 后关弹层（fix: status-popover-mouse-exit-no-close）
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
        // bug: popover-initial-position 第4轮——show 前必须显式告知完整内容尺寸：
        // macOS 26 show 前不执行 SwiftUI 布局（contentSize={0,0}），系统按默认 320
        // 估算定位，内容渲染成 457 高后窗口原点不动 → 顶部冲出菜单栏（实测超屏顶 111pt）。
        // 先触发一次布局取真实 fittingSize（项目先例 CalendarGridView/ReminderAlertView），
        // 异常值退回兜底尺寸，避免硬编码余量在控件高度变化时失效
        let measured = popover.contentViewController?.view.fittingSize
        popover.contentSize = TodayTodoPopoverView.resolvedContentSize(measured: measured)
        // 弹层内容视图装鼠标跟踪（fix: status-popover-mouse-exit-no-close）：
        // 鼠标从弹窗移出（非经图标路径）也要触发关闭检查——与图标移出复用
        // 同一 mouseExited → closeCheckTimer 链
        installPopoverTracking(on: popover.contentViewController?.view)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    /// 给弹层内容视图安装鼠标进入/移出跟踪区。
    /// 弹窗为 .applicationDefined 非 key 窗口，必须 .activeAlways 才能收到跟踪事件；
    /// 弹层内进入触发 openTimer 由 openTimerFired 的 !popover.isShown guard 兜住，无副作用
    func installPopoverTracking(on view: NSView?) {
        guard let view else { return }
        // 幂等：先移除本控制器已装的跟踪区，防重复安装叠加
        for area in view.trackingAreas where area.owner === self {
            view.removeTrackingArea(area)
        }
        view.addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
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

    /// 弹层当前是否展开（点击图标判断用）
    var isPopoverShown: Bool { popover.isShown }

    /// 关闭弹层并取消挂起定时器（点击图标时调用，避免弹层与主面板叠加）
    func closePopover() {
        openTimer?.invalidate()
        openTimer = nil
        closeCheckTimer?.invalidate()
        closeCheckTimer = nil
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    // MARK: - 私有辅助
}
