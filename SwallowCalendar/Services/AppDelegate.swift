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

    // hover 弹层控制器：悬停状态栏图标显示今天待办
    private var hoverController: StatusItemHoverController?

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
        // 构建隐藏主菜单（accessory 应用不显示菜单栏，但 mainMenu 快捷键仍参与
        // key equivalent 匹配——无 Edit 菜单时 Cmd+C/X/V/A 无法路由到文本
        // field editor，应用内全部输入框将无法粘贴复制）
        setupMainMenu()

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

        // 桌面常驻待办面板：注入容器（didSet 时序早于装配场景的兜底见 syncVisibility）
        DesktopTodoPanelManager.shared.configure(with: Self.sharedModelContainer)
        
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

        // 启动补偿：开关已开则显示桌面面板（覆盖 AppSettings.didSet 早于 configure 的时序）
        DesktopTodoPanelManager.shared.syncVisibility()

        // 装配 hover 弹层：条目点击 → 关弹层并打开主面板（主面板已开时 open 仅前置，不会被关掉）
        // 注入 AppSettings 环境（主面板同款）：行内倒计时胶囊需要主题色
        let hover = StatusItemHoverController()
        hover.contentProvider = { [weak hover] in
            NSHostingController(
                rootView: TodayTodoPopoverView(onOpenMainPanel: { hover?.openMainPanel() })
                    .environment(AppSettings.shared)
            )
        }
        if let button = statusItem.button {
            hover.bind(button: button) { [weak self] in
                self?.panel?.open()
            }
        }
        // 弹层显示控制：主面板可见时互斥不弹（挂起而非关闭，面板关闭后可再悬停弹出）；
        // 「显示待办面板」不含菜单栏图标档时同样挂起（无/桌面面板档，动态读取）
        hover.isSuppressed = { [weak self] in
            self?.panel?.isPresented ?? false
                || !AppSettings.shared.todoPanelDisplayMode.menuBarHoverEnabled
        }
        hoverController = hover
    }
    
    /// 构建隐藏主菜单：仅承载文本编辑快捷键（撤销/重做/剪切/拷贝/粘贴/全选）。
    /// 菜单项 target 为 nil，触发时经 responder chain 路由到当前 field editor；
    /// autoenables 默认开启，非文本聚焦态自动禁用，不影响其它快捷键行为。
    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let edit = NSMenu(title: "编辑")

        let addItem: (String, Selector, String, NSEvent.ModifierFlags?) -> Void = { title, action, key, extraMask in
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            if let extraMask { item.keyEquivalentModifierMask = extraMask.union([.command]) }
            edit.addItem(item)
        }
        // undo:/redo: 未在 NSResponder 的 Swift 接口显式暴露，用字符串 Selector 构造
        addItem("撤销", Selector(("undo:")), "z", nil)
        addItem("重做", Selector(("redo:")), "z", [.shift])
        edit.addItem(.separator())
        addItem("剪切", #selector(NSText.cut(_:)), "x", nil)
        addItem("拷贝", #selector(NSText.copy(_:)), "c", nil)
        addItem("粘贴", #selector(NSText.paste(_:)), "v", nil)
        addItem("全选", #selector(NSText.selectAll(_:)), "a", nil)

        let editItem = NSMenuItem()
        editItem.submenu = edit
        mainMenu.addItem(editItem)
        NSApplication.shared.mainMenu = mainMenu
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 应用退出时的清理工作
    }
    
    /// 点击状态栏图标时的处理
    @objc private func performStatusItemClick() {
        // 状态栏 action 固定在主线程，assumeIsolated 进入 MainActor 上下文
        MainActor.assumeIsolated {
            // 点击前先关 hover 弹层，避免弹层与主面板叠加（AC-7：点击行为不变）
            hoverController?.closePopover()
            guard let panel = panel else { return }
            panel.toggle()
        }
    }
    
    /// 点击菜单栏图标但窗口未显示时调用
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            // 弹层与主面板互斥：dock 打开主面板前关 hover 弹层
            hoverController?.closePopover()
            panel?.toggle()
        }
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
