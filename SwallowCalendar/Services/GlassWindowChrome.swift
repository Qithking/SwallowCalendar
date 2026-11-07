//
//  GlassWindowChrome.swift
//  SwallowCalendar
//
//  玻璃弹窗的公共窗口装配（「修改事项」与「批量添加」共用）：
//  透明窗口 + fullSize 标题栏 + 标题栏拖动区落位 + 内容高度顶部锚定。
//  抽取自 EditEventWindowManager，避免两个窗口各写一套标题栏方案。
//

import AppKit
import SwiftUI

@MainActor
enum GlassWindowChrome {
    /// 标题栏高度（fullSize 窗口下内容视图延伸到标题栏之下，窗口总高需补偿这一截）
    static let titlebarHeight: CGFloat = 28
    /// 标题栏拖动区左侧留空：避开交通灯
    static let dragRegionLeadingInset: CGFloat = 80

    /// 创建透明玻璃窗口：标题栏不绘自身背景，由内容视图（VisualEffectView）铺满整窗提供，
    /// 因此标题栏不会出现桌面原图直透的透明带
    static func makeWindow(title: String, contentSize: NSSize) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(
                origin: .zero,
                size: NSSize(width: contentSize.width, height: contentSize.height + titlebarHeight)
            ),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        // 拖动由标题栏拖动区接管，背景拖动保持关闭，避免在输入框/按钮上误拖窗口
        window.isMovableByWindowBackground = false
        // 关闭后引用由 manager 释放，避免悬垂
        window.isReleasedWhenClosed = false
        return window
    }

    /// 装配窗口内容：宿主视图与标题栏拖动区必须是**兄弟视图**，不能把拖动区
    /// 加进 NSHostingView 的子视图（SwiftUI 明确不支持，会破坏视图层级并触发运行时警告）。
    /// 结构：window.contentView（容器 NSView）→ [NSHostingView, TitlebarDragRegionView(最上层)]
    ///
    /// 返回拖动区，便于取证/调试读取实际 frame。
    @discardableResult
    static func installContentView(
        on window: NSWindow,
        hostingView: NSView
    ) -> TitlebarDragRegionView {
        // 容器为非翻转坐标系（普通 NSView），落位函数会按 isFlipped=false 贴顶
        let container = NSView(frame: hostingView.frame)
        hostingView.frame = container.bounds
        hostingView.autoresizingMask = [.width, .height]
        container.addSubview(hostingView)

        // 先让窗口接管容器，容器 bounds 才会等于实际内容尺寸，拖动区落位才准确
        window.contentView = container

        let placement = dragRegionPlacement(
            inBounds: container.bounds,
            isFlipped: container.isFlipped,
            leadingInset: dragRegionLeadingInset
        )
        let region = TitlebarDragRegionView(frame: placement.frame)
        region.autoresizingMask = placement.autoresizingMask
        // 追加在宿主视图之后 → 位于其上方；只覆盖标题栏空白区，不碰底部操作行
        container.addSubview(region)
        return region
    }

    /// 标题栏拖动区落位：坐标系不同，贴顶写法相反。
    /// - 翻转坐标系（如 NSHostingView）：贴顶 y = 0，弹性留白在底侧 → `.maxYMargin`
    /// - 非翻转坐标系（窗口内容容器）：贴顶 y = 高度 - 28，弹性留白在底侧 → `.minYMargin`
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

    /// 内容高度 → 顶部锚定后的窗口 frame（高度封顶由调用方传入的 maxHeight 决定）。
    /// 顶部锚定：只向下生长/向上收缩，窗口位置不上下跳动；宽度不变。
    /// 高度变化不足 1pt 时返回 nil，避免无意义的 setFrame
    static func topAnchoredFrame(
        currentFrame: NSRect,
        contentHeight: CGFloat,
        maxHeight: CGFloat
    ) -> NSRect? {
        let clamped = min(max(contentHeight, 1), maxHeight)
        let targetHeight = clamped + titlebarHeight
        guard abs(targetHeight - currentFrame.height) > 0.5 else { return nil }
        var frame = currentFrame
        frame.origin.y -= targetHeight - currentFrame.height
        frame.size.height = targetHeight
        return frame
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
