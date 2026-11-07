//
//  BatchAddWindowManager.swift
//  SwallowCalendar
//
//  管理批量添加弹窗（独立窗口，spec: batch-add-events）
//

import SwiftUI
import AppKit

@MainActor
final class BatchAddWindowManager {
    static let shared = BatchAddWindowManager()

    private var window: NSWindow?
    private var windowDelegate: BatchAddWindowDelegate?
    // R-23：onTaskAdded 经间接层转发——窗口存活期间主面板重开会用新闭包再次 open，
    // 原复用分支静默忽略新闭包，rootView 持有的仍是旧面板刷新回调（refreshTrigger
    // toggle 到已废弃实例）；闭包无法比较相等，间接层保证始终调用最新回调
    private var onTaskAddedHandler: (() -> Void)?
    /// 最近一次内容自然高度；首帧回调可能早于窗口创建，建窗后据此补做一次尺寸对齐
    private var measuredContentHeight: CGFloat = 0

    private init() {}

    func open(calendarService: CalendarService, appSettings: AppSettings, onTaskAdded: @escaping () -> Void, preview: BatchAddPreviewState? = nil) {
        onTaskAddedHandler = onTaskAdded
        // 已有窗口则置前即可，不重复创建（保留用户输入；rootView 经间接层已指向最新回调。
        // calendarService 为无状态共享服务，旧引用与最新引用功能等价，无漂移风险）
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let rootView = BatchAddView(
            calendarService: calendarService,
            onClose: { [weak self] in self?.window?.close() },
            onTaskAdded: { [weak self] in self?.onTaskAddedHandler?() },
            preview: preview,
            onContentHeightChange: { [weak self] height in
                self?.applyContentHeight(height)
            }
        )
        .environment(appSettings)
        .tint(Color(hex: appSettings.accentColorHex))

        // 与「修改事项」同一套透明玻璃窗口：fullSize 标题栏由内容视图的玻璃铺满
        let hostingView = NSHostingView(rootView: rootView)
        let newWindow = GlassWindowChrome.makeWindow(
            title: "批量添加",
            contentSize: NSSize(width: BatchAddView.contentWidth, height: contentSizeHeight)
        )
        // 拖动区只盖标题栏空白区（避开交通灯与底部操作行），复用编辑窗口修好的落位逻辑
        GlassWindowChrome.installContentView(on: newWindow, hostingView: hostingView)
        newWindow.center()
        newWindow.hidesOnDeactivate = false
        newWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        windowDelegate = BatchAddWindowDelegate()
        newWindow.delegate = windowDelegate
        window = newWindow

        NSApp.activate(ignoringOtherApps: true)
        newWindow.makeKeyAndOrderFront(nil)

        // 首帧内容高度可能已在建窗前回调，这里补做一次尺寸对齐
        if measuredContentHeight > 0 {
            applyContentHeight(measuredContentHeight)
        }
    }

    /// 建窗初始内容高度：编辑区 + 分隔线 + 操作栏（后续由内容测量值校正）
    private var contentSizeHeight: CGFloat {
        BatchAddView.editorAreaHeight + 53
    }

    /// 内容高度变化 → 顶部锚定调整窗口高度；超过上限时封顶，内部滚动由视图承载
    private func applyContentHeight(_ height: CGFloat) {
        measuredContentHeight = height
        guard let window else { return }
        guard let frame = GlassWindowChrome.topAnchoredFrame(
            currentFrame: window.frame,
            contentHeight: height,
            maxHeight: BatchAddView.maxContentHeight
        ) else { return }
        window.setFrame(frame, display: true)
    }

    func windowDidClose() {
        window = nil
        windowDelegate = nil
        measuredContentHeight = 0
    }
}

private final class BatchAddWindowDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        BatchAddWindowManager.shared.windowDidClose()
    }
}
