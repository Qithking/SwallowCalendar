//
//  EditEventWindowManager.swift
//  SwallowCalendar
//

import AppKit
import SwiftUI

@MainActor
final class EditEventWindowManager: NSObject, NSWindowDelegate {
    static let shared = EditEventWindowManager()

    private var editWindow: NSWindow?
    private var isOpening = false
    /// 最近一次内容自然高度；首帧回调可能早于窗口创建，建窗后据此补做一次尺寸对齐
    private var measuredContentHeight: CGFloat = 0
    /// 标题栏高度（fullSize 窗口下内容视图延伸到标题栏之下，窗口总高需补偿这一截）
    /// 非 private：拖动区落位回归测试需以此为基准比对（28pt 为系统标题栏高度）
    static let titlebarHeight: CGFloat = 28

    // 继承 NSObject 后与父类 designated init 同签名，需 override
    private override init() {}

    func openEditWindow(event: CalendarEvent, calendarService: CalendarService, onDismiss: @escaping () -> Void, onSave: @escaping () -> Void = { }, preview: EditPreviewState? = nil) {
        guard !isOpening else { return }

        // 关闭已有窗口
        editWindow?.close()
        measuredContentHeight = 0

        isOpening = true
        defer { isOpening = false }

        let editView = EditEventSheet(
            event: event,
            calendarService: calendarService,
            onDismiss: { [weak self] in
                // E-8：弱引用闭包，打破 manager→window→rootView 闭包→manager 保留环
                self?.editWindow?.close()
                onDismiss()
            },
            onSave: {
                onSave()
            },
            preview: preview,
            onContentHeightChange: { [weak self] height in
                self?.applyContentHeight(height)
            }
        )

        // 宽度由视图内部固定（.frame(width: 340)）；高度由内容测量回调驱动
        let hostingView = NSHostingView(rootView: editView)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 340, height: Self.titlebarHeight + 460)),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "修改事项"
        window.titleVisibility = .visible
        // 标题栏自身不绘背景；底色由 contentView 里的 VisualEffectView（与主面板同一材质）
        // 经 ignoresSafeArea 铺满整窗（含标题栏）提供
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        // 拖动由标题栏拖动区接管，背景拖动保持关闭，避免在输入框/按钮上误拖窗口
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.delegate = self

        window.contentView = hostingView

        // 标题栏拖动区：只叠在标题栏空白区（x=80 起避开左侧交通灯），随窗口高度变化贴顶。
        // 注意 contentView（NSHostingView）是翻转坐标系（isFlipped == true）：若直接按
        // y = 高度 - 28 摆放，会落到窗口底部（正是底部操作行「取消/保存」的位置），
        // 拖动区又加在 SwiftUI 内容之上，会把按钮点击当成窗口拖动吞掉。
        let placement = Self.dragRegionPlacement(
            inBounds: hostingView.bounds,
            isFlipped: hostingView.isFlipped,
            leadingInset: 80
        )
        let dragRegion = TitlebarDragRegionView(frame: placement.frame)
        dragRegion.autoresizingMask = placement.autoresizingMask
        hostingView.addSubview(dragRegion)

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        editWindow = window

        // 首帧内容高度可能已在建窗前回调，这里补做一次尺寸对齐
        if measuredContentHeight > 0 {
            applyContentHeight(measuredContentHeight)
        }
    }

    /// 标题栏拖动区落位：坐标系不同，贴顶写法相反。
    /// - 翻转坐标系（NSHostingView）：贴顶 y = 0，弹性留白在底侧 → `.maxYMargin`
    /// - 非翻转坐标系：贴顶 y = 高度 - 28，弹性留白在底侧 → `.minYMargin`
    /// 实测依据：翻转视图中 `.minYMargin` 会让拖动区随窗口变高下移（曾落到窗口底部按钮行）
    static func dragRegionPlacement(
        inBounds bounds: NSRect,
        isFlipped: Bool,
        leadingInset: CGFloat
    ) -> (frame: NSRect, autoresizingMask: NSView.AutoresizingMask) {
        let y = isFlipped ? 0 : bounds.height - titlebarHeight
        let frame = NSRect(
            x: leadingInset,
            y: y,
            width: max(0, bounds.width - leadingInset),
            height: titlebarHeight
        )
        return (frame, isFlipped ? [.width, .maxYMargin] : [.width, .minYMargin])
    }

    /// 内容高度变化 → 顶部锚定调整窗口高度；超过上限时高度封顶，内部滚动由视图承载
    private func applyContentHeight(_ height: CGFloat) {
        measuredContentHeight = height
        guard let window = editWindow else { return }
        let contentHeight = min(max(height, 1), EditEventSheet.maxContentHeight)
        let targetHeight = contentHeight + Self.titlebarHeight
        let delta = targetHeight - window.frame.height
        guard abs(delta) > 0.5 else { return }
        var frame = window.frame
        // 顶部锚定：只向下生长/向上收缩，窗口位置不上下跳动
        frame.origin.y -= delta
        frame.size.height = targetHeight
        window.setFrame(frame, display: true)
    }

    /// E-8：窗口红叉关闭时清空引用，打断 manager→window 保留链（红叉路径也断链）
    func windowWillClose(_ notification: Notification) {
        editWindow = nil
    }

    /// 取证定位：把编辑窗口摆到主面板旁边（仅调试入口调用，便于同屏对比材质）
    func positionBeside(panelFrame: NSRect, screen: NSScreen?) {
        guard let window = editWindow, let screen else { return }
        let visible = screen.visibleFrame
        var frame = window.frame
        // 优先放在主面板右侧，便于同屏对比；放不下再退化到左侧
        frame.origin.x = panelFrame.maxX + 16
        frame.origin.y = panelFrame.maxY - frame.height
        if frame.maxX > visible.maxX {
            frame.origin.x = panelFrame.minX - frame.width - 16
        }
        // 高度变化后仍完整落在屏幕可见区内
        frame.origin.y = max(
            visible.minY + 8,
            min(frame.origin.y, visible.maxY - frame.height - 8)
        )
        window.setFrame(frame, display: true)
    }
}

/// 标题栏拖动区：fullSize 窗口的标题栏空白区会被内容视图接管，
/// 用不绘制的 AppKit 视图承接拖动，单击拖动窗口、双击缩放（保留系统标题栏习惯）
final class TitlebarDragRegionView: NSView {
    /// 按下瞬间的窗口原点与全局鼠标位置（差值绝对定位，无累计误差）
    private var windowOrigin: NSPoint?
    private var mouseOrigin: NSPoint?

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            window.zoom(nil)
            return
        }
        windowOrigin = window.frame.origin
        mouseOrigin = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let windowOrigin, let mouseOrigin else { return }
        let mouse = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(
            x: windowOrigin.x + (mouse.x - mouseOrigin.x),
            y: windowOrigin.y + (mouse.y - mouseOrigin.y)
        ))
    }

    override func mouseUp(with event: NSEvent) {
        windowOrigin = nil
        mouseOrigin = nil
    }
}
