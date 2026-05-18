//
//  AppDelegate.swift
//  SwallowCalendar
//
//  管理状态栏图标和主窗口

import SwiftUI
import AppKit
import SwiftData

class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: FloatingPanel<AnyView>?
    
    // 全局共享的 ModelContainer
    static var sharedModelContainer: ModelContainer!
    
    // 状态栏图标
    private lazy var statusItem: NSStatusItem = {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.behavior = .removalAllowed
        item.button?.action = #selector(performStatusItemClick)
        item.button?.target = self
        item.button?.imagePosition = .imageLeft
        // 绑定到 StatusBarIconManager，使图标更新能自动同步
        StatusBarIconManager.shared.bind(statusItem: item)
        return item
    }()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 设置状态栏图标
        updateStatusItemIcon()
        
        // 创建全局共享的 ModelContainer
        Self.sharedModelContainer = Self.createModelContainer()
        
        // 配置事件缓存服务（使用共享容器）
        EventCacheService.shared.configure(with: Self.sharedModelContainer)

        BackgroundSyncService.shared.configure(with: Self.sharedModelContainer)
        BackgroundSyncService.shared.start()
        
        // 配置设置窗口管理器（使用共享容器）
        SettingsWindowManager.shared.modelContainer = Self.sharedModelContainer
        
        // 检查更新
        UpdateChecker.shared.checkOnStartup()
        UpdateChecker.shared.startPeriodicCheck()
        
        // 启动待办事项到期提醒服务
        ReminderAlertService.shared.configure(with: Self.sharedModelContainer)
        ReminderAlertService.shared.startMonitoring()
        
        // 创建 FloatingPanel（使用共享容器）
        panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: CGSize(width: 340, height: 600)),
            identifier: "SwallowCalendarMainWindow",
            statusBarButton: statusItem.button,
            onClose: {}
        ) {
            let settings = AppSettings.shared
            
            AnyView(
                ContentView()
                    .environment(settings)
                    .modelContainer(Self.sharedModelContainer)
            )
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // 应用退出时的清理工作
    }
    
    /// 点击状态栏图标时的处理
    @objc private func performStatusItemClick() {
        guard let panel = panel else { return }
        panel.toggle()
    }
    
    /// 点击菜单栏图标但窗口未显示时调用
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel?.toggle()
        return true
    }
    
    /// 更新状态栏图标
    func updateStatusItemIcon() {
        statusItem.button?.image = StatusBarIconManager.shared.currentIcon
    }
    
    /// 创建 ModelContainer
    private static func createModelContainer() -> ModelContainer {
        // 指定明确的存储路径，确保数据持久化稳定
        let storeURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("SwallowCalendar")
            .appendingPathComponent("default.store")
        
        // 确保目录存在
        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        
        let modelConfiguration = ModelConfiguration(
            url: storeURL,
            isStoredInMemoryOnly: false,
            allowsSave: true
        )
        
        do {
            return try ModelContainer(
                for: AppSchemaMigrationPlan.self,
                configurations: modelConfiguration
            )
        } catch {
            fatalError("创建 ModelContainer 失败: \(error)")
        }
    }
}
