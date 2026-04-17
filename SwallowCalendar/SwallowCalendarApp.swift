//
//  SwallowCalendarApp.swift
//  SwallowCalendar
//

import SwiftUI
import SwiftData

@main
struct SwallowCalendarApp: App {
    @State private var appSettings = AppSettings.shared
    @State private var iconManager = StatusBarIconManager.shared

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            CalendarPreference.self,
            CustomCalendarSource.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environment(appSettings)
                .modelContainer(sharedModelContainer)
                .frame(minWidth: 340, minHeight: 600)
        } label: {
            StatusBarLabelView()
        }
        .menuBarExtraStyle(.window)
    }

    init() {
        // 设置 SettingsWindowManager 的依赖
        SettingsWindowManager.shared.modelContainer = sharedModelContainer
        SettingsWindowManager.shared.appSettings = appSettings
    }
}

/// 状态栏标签视图，响应图标更新
struct StatusBarLabelView: View {
    @State private var iconManager = StatusBarIconManager.shared

    var body: some View {
        Image(nsImage: iconManager.currentIcon)
    }
}

/// 使用 NSWindow 管理设置窗口，避免 MenuBarExtra + Window scene 的 ViewBridge 崩溃
@MainActor
final class SettingsWindowManager {
    static let shared = SettingsWindowManager()

    var modelContainer: ModelContainer?
    var appSettings: AppSettings?
    private var settingsWindow: NSWindow?

    private init() {}

    func openSettings() {
        if let window = settingsWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingView = NSHostingView(rootView:
            SettingsView()
                .environment(appSettings ?? AppSettings.shared)
                .modelContainer(modelContainer ?? createFallbackModelContainer())
                .frame(minWidth: 450, minHeight: 400)
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 450),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "设置"
        window.contentView = hostingView
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.delegate = SettingsWindowDelegate(manager: self)
        NSApp.activate(ignoringOtherApps: true)

        settingsWindow = window
    }

    func windowDidClose() {
        settingsWindow = nil
    }

    private func createFallbackModelContainer() -> ModelContainer {
        let schema = Schema([CalendarPreference.self, CustomCalendarSource.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        if let container = try? ModelContainer(for: schema, configurations: [config]) {
            return container
        }
        // 最终兜底：内存模式
        return try! ModelContainer(for: CalendarPreference.self, CustomCalendarSource.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
}

private class SettingsWindowDelegate: NSObject, NSWindowDelegate {
    let manager: SettingsWindowManager

    init(manager: SettingsWindowManager) {
        self.manager = manager
    }

    func windowWillClose(_ notification: Notification) {
        manager.windowDidClose()
    }
}
