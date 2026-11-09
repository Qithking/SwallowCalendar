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
                // 弱引用闭包，打破 manager→window→rootView 闭包→manager 保留环
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

        let window = GlassWindowChrome.makeWindow(
            title: "修改事项",
            contentSize: NSSize(width: 340, height: 460)
        )
        window.delegate = self

        // 标题栏拖动区：只叠在标题栏空白区（x=80 起避开左侧交通灯），与宿主视图为兄弟视图。
        // 不能把拖动区加进 NSHostingView（SwiftUI 不支持，会破坏层级）；
        // 贴顶落位由共用装配按容器坐标系处理，避免拖动区落到窗口底部、盖住「取消/保存」按钮。
        GlassWindowChrome.installContentView(on: window, hostingView: hostingView)

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        editWindow = window

        // 首帧内容高度可能已在建窗前回调，这里补做一次尺寸对齐
        if measuredContentHeight > 0 {
            applyContentHeight(measuredContentHeight)
        }
    }

    /// 内容高度变化 → 顶部锚定调整窗口高度；超过上限时高度封顶，内部滚动由视图承载
    private func applyContentHeight(_ height: CGFloat) {
        measuredContentHeight = height
        guard let window = editWindow else { return }
        guard let frame = GlassWindowChrome.topAnchoredFrame(
            currentFrame: window.frame,
            contentHeight: height,
            maxHeight: EditEventSheet.maxContentHeight
        ) else { return }
        window.setFrame(frame, display: true)
    }

    /// 窗口红叉关闭时清空引用，打断 manager→window 保留链（红叉路径也断链）
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

/// 标题栏拖动区与窗口装配已抽取到 GlassWindowChrome.swift，供编辑/批量添加两个窗口共用
