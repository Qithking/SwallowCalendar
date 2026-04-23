//
//  AppDelegate.swift
//  SwallowCalendar
//
//  参考 Maccy 项目实现，管理状态栏图标和主窗口

import SwiftUI
import AppKit
import SwiftData

class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: FloatingPanel<AnyView>?
    
    // 状态栏图标
    private lazy var statusItem: NSStatusItem = {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.behavior = .removalAllowed
        item.button?.action = #selector(performStatusItemClick)
        item.button?.target = self
        item.button?.imagePosition = .imageLeft
        return item
    }()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 设置状态栏图标
        updateStatusItemIcon()
        
        // 配置事件缓存服务
        let container = Self.createModelContainer()
        EventCacheService.shared.configure(with: container)
        
        // 检查更新
        UpdateChecker.shared.checkOnStartup()
        UpdateChecker.shared.startPeriodicCheck()
        
        // 创建 FloatingPanel
        panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: CGSize(width: 340, height: 600)),
            identifier: "SwallowCalendarMainWindow",
            statusBarButton: statusItem.button,
            onClose: {}
        ) {
            let container = Self.createModelContainer()
            let settings = AppSettings.shared
            
            AnyView(
                ContentView()
                    .environment(settings)
                    .modelContainer(container)
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
    }
}
