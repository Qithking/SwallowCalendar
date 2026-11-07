//
//  WindowDrag.swift
//  SwallowCalendar
//
//  内容铺满整窗（无可见标题栏）时的整窗拖动，桌面待办面板与编辑窗口共用同一套实现
//  来源：DesktopTodoPanelView 七轮定稿的 DragGesture 方案
//

import SwiftUI
import AppKit

/// 拖动起点快照（按下瞬间：窗口 origin + 全局鼠标位置）
struct WindowDragOrigin {
    let windowOrigin: CGPoint
    let mouse: CGPoint
}

extension View {
    /// 给内容/背景加整窗拖动：
    /// - `DragGesture(minimumDistance: 5)` 区分点击与拖动，>5pt 才移窗，控件点击不受影响
    /// - `onChanged` 用 `NSEvent.mouseLocation` 全局坐标做绝对定位（起点快照 + 差值），无累计误差
    /// - 起点只在首帧写一次 @State、松开清空，拖动过程零 SwiftUI 重排
    func windowBackgroundDrag() -> some View {
        modifier(WindowBackgroundDragModifier())
    }
}

private struct WindowBackgroundDragModifier: ViewModifier {
    @State private var dragStart: WindowDragOrigin?

    func body(content: Content) -> some View {
        content.gesture(
            DragGesture(minimumDistance: 5)
                .onChanged { _ in
                    // 拖动回调时 currentEvent 即本窗口的鼠标事件
                    guard let window = NSApp.currentEvent?.window else { return }
                    let mouse = NSEvent.mouseLocation
                    if dragStart == nil {
                        dragStart = WindowDragOrigin(windowOrigin: window.frame.origin, mouse: mouse)
                    }
                    guard let start = dragStart else { return }
                    window.setFrameOrigin(
                        CGPoint(x: start.windowOrigin.x + (mouse.x - start.mouse.x),
                                y: start.windowOrigin.y + (mouse.y - start.mouse.y))
                    )
                }
                .onEnded { _ in dragStart = nil }
        )
    }
}
