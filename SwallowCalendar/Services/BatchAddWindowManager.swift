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

    private init() {}

    func open(calendarService: CalendarService, appSettings: AppSettings, onTaskAdded: @escaping () -> Void) {
        // 已有窗口则置前即可，不重复创建
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let rootView = BatchAddView(
            calendarService: calendarService,
            onClose: { [weak self] in self?.window?.close() },
            onTaskAdded: onTaskAdded
        )
        .environment(appSettings)
        .tint(Color(hex: appSettings.accentColorHex))

        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "批量添加"
        newWindow.contentView = NSHostingView(rootView: rootView)
        newWindow.center()
        // isReleasedWhenClosed=false：窗口关闭后引用由 manager 释放，避免悬垂
        newWindow.isReleasedWhenClosed = false
        newWindow.hidesOnDeactivate = false
        newWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        windowDelegate = BatchAddWindowDelegate()
        newWindow.delegate = windowDelegate
        window = newWindow

        NSApp.activate(ignoringOtherApps: true)
        newWindow.makeKeyAndOrderFront(nil)
    }

    func windowDidClose() {
        window = nil
        windowDelegate = nil
    }
}

private final class BatchAddWindowDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        BatchAddWindowManager.shared.windowDidClose()
    }
}
