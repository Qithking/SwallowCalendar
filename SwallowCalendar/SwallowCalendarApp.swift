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
            fatalError("创建 ModelContainer 失败: \(error)")
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
        // 设置 SettingsWindowManager 的依赖（使用静态引用确保窗口能访问）
        SettingsWindowManager.sharedModelContainer = sharedModelContainer
        SettingsWindowManager.sharedAppSettings = appSettings

        // 配置事件缓存服务
        EventCacheService.shared.configure(with: sharedModelContainer)

        // 检查更新
        UpdateChecker.shared.checkOnStartup()
        UpdateChecker.shared.startPeriodicCheck()
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

    // 存储主应用的 modelContainer 引用
    static var sharedModelContainer: ModelContainer?
    static var sharedAppSettings: AppSettings?

    var modelContainer: ModelContainer?
    var appSettings: AppSettings?
    private var settingsWindow: NSWindow?
    private var settingsWindowDelegate: SettingsWindowDelegate?
    private var isOpening = false

    private init() {}

    func openSettings() {
        // 防止重复打开
        guard !isOpening else { return }

        // 已有窗口则直接激活并置顶
        if let window = settingsWindow {
            window.level = .floating  // 确保浮动在最上层
            
            // 强制激活应用并显示窗口
            DispatchQueue.main.async {
                // 1. 先激活应用
                NSApp.activate(ignoringOtherApps: true)
                
                // 2. 显示窗口
                if window.isVisible {
                    window.makeKeyAndOrderFront(nil)
                } else {
                    window.orderFront(nil)
                }
                
                // 3. 确保窗口获取焦点
                window.makeKey()
                window.becomeKey()
                
                // 4. 再次确认应用激活
                NSApp.activate(ignoringOtherApps: true)
            }
            return
        }

        isOpening = true
        defer { isOpening = false }

        // 优先使用主应用传入的 container，否则使用共享静态引用，最后才创建新容器
        let container = modelContainer ?? Self.sharedModelContainer ?? createFallbackModelContainer()
        let settings = appSettings ?? Self.sharedAppSettings ?? AppSettings.shared

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
        window.level = .floating  // 设置为浮动窗口，保持在最上层
        settingsWindowDelegate = SettingsWindowDelegate()
        window.delegate = settingsWindowDelegate
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false  // 失焦时不隐藏
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]  // 确保在所有空间中可用
        
        settingsWindow = window
        
        // 强制激活应用并显示窗口
        DispatchQueue.main.async {
            // 1. 先激活应用
            NSApp.activate(ignoringOtherApps: true)
            
            // 2. 显示窗口并设为关键窗口
            window.makeKeyAndOrderFront(nil)
            
            // 3. 确保窗口获取焦点
            window.becomeKey()
            
            // 4. 再次确认应用激活
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func windowDidClose() {
        settingsWindow = nil
    }

    private func createFallbackModelContainer() -> ModelContainer {
        let schema = Schema([CalendarPreference.self, CustomCalendarSource.self, CachedEvent.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        if let container = try? ModelContainer(for: schema, configurations: [config]) {
            return container
        }
        return try! ModelContainer(for: CalendarPreference.self, CustomCalendarSource.self, CachedEvent.self)
    }
}

private class SettingsWindowDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        SettingsWindowManager.shared.windowDidClose()
    }
}
