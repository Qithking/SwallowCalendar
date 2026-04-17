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
            CachedEvent.self,
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
        
        // 配置事件缓存服务
        EventCacheService.shared.configure(with: sharedModelContainer)
    }
}

/// 状态栏标签视图，响应图标更新
struct StatusBarLabelView: View {
    @State private var iconManager = StatusBarIconManager.shared

    var body: some View {
        Button {
            // 空白动作，图标点击由 MenuBarExtra 本身处理
        } label: {
            Image(nsImage: iconManager.currentIcon)
        }
        .buttonStyle(.plain)
    }
}

/// 使用 NSWindow 管理设置窗口，避免 MenuBarExtra + Window scene 的 ViewBridge 崩溃
@MainActor
final class SettingsWindowManager {
    static let shared = SettingsWindowManager()

    var modelContainer: ModelContainer?
    var appSettings: AppSettings?
    private var settingsWindow: NSWindow?
    private var settingsWindowDelegate: SettingsWindowDelegate?
    private var isOpening = false

    private init() {}

    func openSettings() {
        // 防止重复打开
        guard !isOpening else { return }

        // 已有窗口则直接激活
        if let window = settingsWindow {
            if window.isVisible {
                window.makeKeyAndOrderFront(nil)
            } else {
                // 窗口可能被隐藏，重新显示
                window.orderFront(nil)
            }
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        isOpening = true
        defer { isOpening = false }

        let container = modelContainer ?? createFallbackModelContainer()
        let settings = appSettings ?? AppSettings.shared

        let settingsView = SettingsView()
            .environment(settings)
            .modelContainer(container)
            .tint(Color(hex: settings.accentColorHex))

        let hostingView = NSHostingView(rootView: settingsView.frame(minWidth: 450, minHeight: 400))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 450),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "设置"
        window.contentView = hostingView
        window.center()
        settingsWindowDelegate = SettingsWindowDelegate()
        window.delegate = settingsWindowDelegate
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        settingsWindow = window
    }

    func windowDidClose() {
        settingsWindow = nil
    }

    private func createFallbackModelContainer() -> ModelContainer {
        let schema = Schema([CalendarPreference.self, CustomCalendarSource.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        if let container = try? ModelContainer(for: schema, configurations: [config]) {
            return container
        }
        return try! ModelContainer(for: CalendarPreference.self, CustomCalendarSource.self)
    }
}

private class SettingsWindowDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        SettingsWindowManager.shared.windowDidClose()
    }
}
