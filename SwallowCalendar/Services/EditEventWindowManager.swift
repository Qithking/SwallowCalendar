//
//  EditEventWindowManager.swift
//  SwallowCalendar
//

import AppKit
import SwiftUI

@MainActor
final class EditEventWindowManager {
    static let shared = EditEventWindowManager()

    private var editWindow: NSWindow?
    private var isOpening = false

    private init() {}

    func openEditWindow(event: CalendarEvent, calendarService: CalendarService, onDismiss: @escaping () -> Void, onSave: @escaping () -> Void = { }) {
        guard !isOpening else { return }

        // 关闭已有窗口
        editWindow?.close()

        isOpening = true
        defer { isOpening = false }

        let editView = EditEventSheet(
            event: event,
            calendarService: calendarService,
            onDismiss: {
                self.editWindow?.close()
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
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        editWindow = window
    }

    func closeEditWindow() {
        editWindow?.close()
        editWindow = nil
    }
}
