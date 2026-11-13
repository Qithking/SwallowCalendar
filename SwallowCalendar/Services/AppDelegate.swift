//
//  AppDelegate.swift
//  SwallowCalendar
//
//  管理状态栏图标和主窗口

import SwiftUI
import AppKit
import SwiftData
import EventKit

class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: FloatingPanel<AnyView>?

    // hover 弹层控制器：悬停状态栏图标显示今天待办
    private var hoverController: StatusItemHoverController?

    // 全局共享的 ModelContainer
    static var sharedModelContainer: ModelContainer!
    
    // 状态栏图标
    private lazy var statusItem: NSStatusItem = {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // 不设置 behavior 即保持默认不可移除（AppKit 无 .removalDisallowed，
        // 默认空值已禁止 Cmd+拖除；显式 .removalAllowed 才会开放移除）——accessory
        // 应用无 Dock 图标与菜单栏恢复入口，图标被拖除后唯一入口消失且无法自行恢复
        item.button?.action = #selector(performStatusItemClick(_:))
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
        
        // 检查更新（预览取证态跳过启动检查，避免更新弹窗遮挡编辑/批量添加窗口；
        // 判断口径与下方调试入口一致：能解析出有效预览态（1/tall）才视为预览模式）
        // 诊断态（SC_DIAG_REAL=1）同样跳过：更新弹窗与启动授权门弹窗干扰调试
        // （用户反馈：每次启动调试实例都弹授权框）
        let isDiagMode = ProcessInfo.processInfo.environment["SC_DIAG_REAL"] == "1"
        let isPreviewMode = isDiagMode
            || ProcessInfo.processInfo.environment["SC_OPEN_EDIT_PREVIEW"] == "1"
            || Self.batchAddPreviewState() != nil
        if !isPreviewMode {
            UpdateChecker.shared.checkOnStartup()
        }
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

        // 取证：SC_DIAG_WINDOW=1 时自动打开主面板（无需手动点击状态栏），
        // 使 MonthEventGrid 的 @Query 真实执行，便于 log stream 抓取
        if ProcessInfo.processInfo.environment["SC_DIAG_WINDOW"] == "1" {
            DispatchQueue.main.async { [weak self] in
                self?.panel?.open()
            }
        }

        // 调试入口：SC_OPEN_EDIT_PREVIEW=1 时启动即打开「修改事项」窗口（填入示例数据），
        // 供无 UI 自动化权限时用 screencapture 取证标题栏与玻璃外观；
        // 仅在环境变量命中时生效，正常启动零影响
        if ProcessInfo.processInfo.environment["SC_OPEN_EDIT_PREVIEW"] == "1" {
            DispatchQueue.main.async {
                EditEventWindowManager.shared.openEditWindow(
                    event: Self.editPreviewEvent(),
                    calendarService: CalendarService.shared,
                    onDismiss: {},
                    preview: Self.editPreviewState()
                )
            }
            // 取证：主面板同时打开时，把编辑窗口摆到面板旁边，同屏对比透明度
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let panel = self?.panel else { return }
                EditEventWindowManager.shared.positionBeside(
                    panelFrame: panel.frame,
                    screen: panel.screen
                )
            }
        }

        // 调试入口：SC_OPEN_BATCH_ADD_PREVIEW=1 启动即打开「批量添加」窗口（默认态）；
        // =tall 时展示多条失败结果，用于验证内容增多后的高态与滚动上限。
        // 仅环境变量命中时生效，正常启动零影响
        if let preview = Self.batchAddPreviewState() {
            DispatchQueue.main.async {
                BatchAddWindowManager.shared.open(
                    calendarService: CalendarService.shared,
                    appSettings: AppSettings.shared,
                    onTaskAdded: {},
                    preview: preview
                )
            }
        }

        // 启动补偿：开关已开则显示桌面面板（覆盖 AppSettings.didSet 早于 configure 的时序）
        DesktopTodoPanelManager.shared.syncVisibility()

        // 装配 hover 弹层：条目文字不可点击唤起主面板（仅图标点击触发，
        // 守卫测试 StatusPopoverEntryClickGuardTests 把关）。
        // 注入 AppSettings 环境（主面板同款）：行内倒计时胶囊需要主题色
        let hover = StatusItemHoverController()
        hover.contentProvider = {
            NSHostingController(
                // 初始档在挂载前从记忆档解析定死（show 后切档会触发弹层重排错位）
                rootView: TodayTodoPopoverView(
                    initialMode: TodayTodoPopoverView.resolveInitialMode(from: AppSettings.shared)
                )
                    .environment(AppSettings.shared)
            )
        }
        if let button = statusItem.button {
            hover.bind(button: button)
        }
        // 弹层显示控制：主面板可见时互斥不弹（挂起而非关闭，面板关闭后可再悬停弹出）；
        // 「显示待办面板」不含菜单栏图标档时同样挂起（无/桌面面板档，动态读取）
        hover.isSuppressed = { [weak self] in
            self?.panel?.isPresented ?? false
                || !AppSettings.shared.todoPanelDisplayMode.menuBarHoverEnabled
        }
        hoverController = hover

        // 启动日历授权门（startup-auth-gate）：授权请求原先挂在 ContentView.task，
        // 面板未展开时视图不存在、授权请求从未执行；改挂应用生命周期，
        // 启动即校验日历授权（notDetermined 弹授权框 / denied 引导前往设置）。
        // 预览取证态跳过，避免授权弹窗遮挡取证窗口（口径与 UpdateChecker 一致）
        if !isPreviewMode {
            Task { await runStartupAuthorizationGate() }
        }
    }

    // MARK: - 启动授权门（startup-auth-gate）

    /// 启动时校验日历授权状态并引导授权
    /// - notDetermined：直接弹系统授权框；提醒同步已开启时连带请求提醒（与原启动链路一致）
    /// - denied/restricted：应用内无法再弹系统授权框，弹引导窗对齐提醒 denied 行为
    /// - Note: 仅处理日历；提醒 denied 引导仍由面板展开时 initializeServices 承接，避免重复弹窗
    @MainActor
    private func runStartupAuthorizationGate() async {
        let calendarService = CalendarService.shared
        calendarService.refreshAuthorizationStatus()

        if calendarService.authorizationStatus == .notDetermined {
            let syncReminders = AppSettings.shared.syncSystemReminders
            _ = await calendarService.requestAccess(requestReminders: syncReminders)
        } else if CalendarService.shouldGuideCalendarAccess(calendarService.authorizationStatus) {
            showCalendarAuthGuide()
        }
    }

    /// 弹窗引导用户去系统设置开启日历权限（样式对齐 ContentView.showReminderAuthAlert）
    private func showCalendarAuthGuide() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "需要日历权限"
        alert.informativeText = "请在系统设置中开启「日历」权限，以便同步系统日历事项。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "去开启")
        alert.addButton(withTitle: "忽略")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            CalendarService.shared.openCalendarSettings()
        }
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
    @objc private func performStatusItemClick(_ sender: Any?) {
        // 状态栏 action 固定在主线程，assumeIsolated 进入 MainActor 上下文
        MainActor.assumeIsolated {
            guard let panel = panel else { return }
            if let hover = hoverController, hover.isPopoverShown {
                // 弹层展示时点击图标：面板未显示则先打开面板（成为 key window）
                // 再关弹层——弹层关闭时 app 已有 key 窗口不会失活，失活自动关闭
                // 三链不会误关刚打开的面板（先关后开的顺序已被实测否定：
                // 弹层关闭的失活级联在 open 后 0.8~2.4s 持续触发）。
                // 禁止在此处对失活自动关闭做时间窗抑制：先开后关已消除失活根源，
                // 抑制窗口反而会吞掉用户打开面板后立刻点击面板外部的真实关闭意图
                // （实测：初次点击不关、二次点击才关——fix: popover-click-open-panel）
                if !panel.isPresented {
                    panel.open()
                }
                hover.closePopover()
            } else {
                // 弹层未展示：正常 toggle（无弹层关闭即无失活源，无需抑制窗口）
                panel.toggle()
            }
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
    
    /// 调试预览态选择（SC_OPEN_BATCH_ADD_PREVIEW=1|tall），仅截图取证使用
    private static func batchAddPreviewState() -> BatchAddPreviewState? {
        switch ProcessInfo.processInfo.environment["SC_OPEN_BATCH_ADD_PREVIEW"] {
        case "1":
            return BatchAddPreviewState(sampleText: Self.batchAddPreviewText)
        case "tall":
            // 16 条失败行：超出 maxContentHeight，用于验证封顶后的内部滚动
            return BatchAddPreviewState(sampleText: Self.batchAddPreviewText, failureCount: 16)
        default:
            return nil
        }
    }

    /// 调试预览用示例文本（仅 SC_OPEN_BATCH_ADD_PREVIEW 入口使用，不写入日历）
    private static let batchAddPreviewText = """
    明天下午3点开会 红色 重要
    每天上午9点晨会 循环
    每周五晚上8点复盘
    """

    /// 调试预览态选择（SC_EDIT_PREVIEW_STATE=custom|validity|custom+validity），仅截图取证使用
    private static func editPreviewState() -> EditPreviewState? {
        switch ProcessInfo.processInfo.environment["SC_EDIT_PREVIEW_STATE"] {
        case "custom": return EditPreviewState(customRecurrence: true)
        case "validity": return EditPreviewState(validityOn: true)
        case "custom+validity": return EditPreviewState(customRecurrence: true, validityOn: true)
        default: return nil
        }
    }

    /// 调试预览用示例事件（仅 SC_OPEN_EDIT_PREVIEW 入口使用，不写入缓存与日历）
    private static func editPreviewEvent() -> CalendarEvent {
        CalendarEvent(
            id: "debug-edit-preview",
            title: "示例事项",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            isAllDay: false,
            calendarID: "debug-calendar",
            calendarTitle: "示例日历",
            calendarColorHex: "#007AFF",
            category: .user,
            isCompleted: false,
            priority: 0,
            isReminder: false,
            recurrenceType: .none,
            reminderMinutes: 0,
            eventColorHex: nil
        )
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
