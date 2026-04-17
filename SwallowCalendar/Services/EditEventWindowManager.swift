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

    func openEditWindow(event: CalendarEvent, calendarService: CalendarService, onDismiss: @escaping () -> Void) {
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
            }
        )

        let hostingView = NSHostingView(rootView: editView.frame(width: 350, height: 450))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 350, height: 450),
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
