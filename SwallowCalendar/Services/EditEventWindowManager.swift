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

    // 继承 NSObject 后与父类 designated init 同签名，需 override
    private override init() {}

    func openEditWindow(event: CalendarEvent, calendarService: CalendarService, onDismiss: @escaping () -> Void, onSave: @escaping () -> Void = { }) {
        guard !isOpening else { return }

        // 关闭已有窗口
        editWindow?.close()

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
            }
        )

        // 固定宽度由视图内部提供（.frame(width: 340)），高度按内容 fittingSize 自适应，避免大片空白
        let hostingView = NSHostingView(rootView: editView)
        let contentSize = hostingView.fittingSize

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "修改事件"
        window.contentView = hostingView
        window.delegate = self
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        editWindow = window
    }

    /// E-8：窗口红叉关闭时清空引用，打断 manager→window 保留链（红叉路径也断链）
    func windowWillClose(_ notification: Notification) {
        editWindow = nil
    }
}
