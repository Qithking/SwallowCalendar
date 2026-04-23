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
        print("[AppDelegate] applicationDidFinishLaunching called")
        
        // 设置状态栏图标
        updateStatusItemIcon()
        print("[AppDelegate] Status item created, button exists: \(statusItem.button != nil)")
        
        // 配置事件缓存服务
        let container = Self.createModelContainer()
        EventCacheService.shared.configure(with: container)
        
        // 检查更新
        UpdateChecker.shared.checkOnStartup()
        UpdateChecker.shared.startPeriodicCheck()
        
        // 创建 FloatingPanel
        print("[AppDelegate] Creating FloatingPanel...")
        panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: CGSize(width: 340, height: 600)),
            identifier: "SwallowCalendarMainWindow",
            statusBarButton: statusItem.button,
            onClose: {
                print("[AppDelegate] Panel closed")
            }
        ) {
            // 获取 sharedModelContainer
            let container = Self.createModelContainer()
            let settings = AppSettings.shared
            
            AnyView(
                ContentView()
                    .environment(settings)
                    .modelContainer(container)
            )
        }
        print("[AppDelegate] FloatingPanel created, panel exists: \(panel != nil)")
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // 应用退出时的清理工作
    }
    
    /// 点击状态栏图标时的处理
    @objc private func performStatusItemClick() {
        print("[AppDelegate] Status item clicked!")
        print("[AppDelegate] Panel exists: \(panel != nil)")
        
        guard let panel = panel else {
            print("[AppDelegate] ERROR: Panel is nil!")
            return
        }
        
        print("[AppDelegate] Panel isPresented before toggle: \(panel.isPresented)")
        print("[AppDelegate] Calling panel.toggle()...")
        panel.toggle()
        print("[AppDelegate] panel.toggle() completed")
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
