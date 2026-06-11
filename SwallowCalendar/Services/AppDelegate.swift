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
        // 注意：BackgroundSyncService.start() 不在此处调用，
        // 改由 ContentView.task 注入 mainContext 后再启动，确保使用同一 ModelContext
        
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
    
    /// 创建 ModelContainer（不向下兼容，schema 变更时直接删除旧库重建）
    private static func createModelContainer() -> ModelContainer {
        let schema = Schema([
            CalendarPreference.self,
            CustomCalendarSource.self,
            CachedEvent.self,
        ])
        
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        
        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            let errorDescription = error.localizedDescription
            // 仅在 schema 与旧数据库不匹配时删除旧库重建
            // 其他错误（权限、磁盘满等）删除后也无法恢复，不应丢失数据
            if errorDescription.contains("schema") || errorDescription.contains("migration") || errorDescription.contains("version") || errorDescription.contains("PersistentModel") {
                print("[AppDelegate] Schema 不匹配，删除旧数据库重建: \(error)")
                deleteDatabase()
                do {
                    return try ModelContainer(for: schema, configurations: [modelConfiguration])
                } catch {
                    fatalError("删除旧库后重建 ModelContainer 仍然失败: \(error)")
                }
            } else {
                // 非迁移类错误，不删除数据，直接崩溃报告
                fatalError("创建 ModelContainer 失败（非 schema 问题）: \(error)")
            }
        }
    }
    
    /// 删除 SwiftData 数据库文件
    private static func deleteDatabase() {
        let urls = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        guard let appSupport = urls.first else { return }
        
        // SwiftData 默认数据库路径
        let defaultDB = appSupport
            .appendingPathComponent("default.store", isDirectory: true)
        let defaultDBWal = appSupport
            .appendingPathComponent("default.store-wal", isDirectory: false)
        let defaultDBShm = appSupport
            .appendingPathComponent("default.store-shm", isDirectory: false)
        
        for url in [defaultDB, defaultDBWal, defaultDBShm] {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
