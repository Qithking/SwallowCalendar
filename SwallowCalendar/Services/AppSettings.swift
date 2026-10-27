//
//  AppSettings.swift
//  SwallowCalendar
//

import Foundation
import ServiceManagement
import SwiftUI
import os

@Observable
final class AppSettings {
    static let shared = AppSettings()

    // MARK: - General
    var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
            updateLaunchAtLogin()
        }
    }

    var iconStyle: IconStyle {
        didSet {
            UserDefaults.standard.set(iconStyle.rawValue, forKey: "iconStyleRaw")
            StatusBarIconManager.shared.updateIconAndRestartTimer()
        }
    }

    var customIconFormat: String {
        didSet {
            UserDefaults.standard.set(customIconFormat, forKey: "customIconFormat")
            StatusBarIconManager.shared.updateIconAndRestartTimer()
        }
    }

    /// 自定义格式样式
    var customFormatStyle: CustomFormatStyle {
        didSet {
            UserDefaults.standard.set(customFormatStyle.rawValue, forKey: "customFormatStyle")
            StatusBarIconManager.shared.updateIconAndRestartTimer()
        }
    }

    var themeMode: ThemeMode {
        didSet {
            UserDefaults.standard.set(themeMode.rawValue, forKey: "themeModeRaw")
        }
    }

    /// 星期起始日：1=周日，2=周一（默认值跟随系统）
    var weekdayStart: Int {
        didSet {
            UserDefaults.standard.set(weekdayStart, forKey: "weekdayStart")
        }
    }

    /// 是否显示农历
    var showLunarCalendar: Bool {
        didSet {
            UserDefaults.standard.set(showLunarCalendar, forKey: "showLunarCalendar")
        }
    }

    /// 应用主题色
    var accentColorHex: String {
        didSet {
            UserDefaults.standard.set(accentColorHex, forKey: "accentColorHex")
            StatusBarIconManager.shared.updateIconAndRestartTimer()
        }
    }

    /// 菜单栏显示最近待办事项倒计时徽标（D2，默认关闭）
    var statusBarCountdownEnabled: Bool {
        didSet {
            UserDefaults.standard.set(statusBarCountdownEnabled, forKey: "statusBarCountdownEnabled")
            StatusBarIconManager.shared.updateIconAndRestartTimer()
        }
    }

    /// 「显示待办面板」四态（需求：无/菜单栏图标/桌面面板/两者）——
    /// 菜单栏图标档控制 hover 弹层，桌面面板档控制常驻面板，两者=现有逻辑
    enum TodoPanelDisplayMode: String {
        case none
        case menuBarIcon
        case desktopPanel
        case both

        /// 设置下拉展示名
        var displayTitle: String {
            switch self {
            case .none: return "无"
            case .menuBarIcon: return "菜单栏图标"
            case .desktopPanel: return "桌面面板"
            case .both: return "两者"
            }
        }

        /// 旧 Bool 开关迁移（PanelDisplayModeTests 覆盖）：
        /// true（面板开）→ 两者；false（面板关）→ 菜单栏图标——
        /// hover 弹层历史上不受开关控制，迁移后保持可见，升级用户行为零回归
        static func fromLegacy(enabled: Bool) -> TodoPanelDisplayMode {
            enabled ? .both : .menuBarIcon
        }

        /// 菜单栏图标 hover 弹层是否显示
        var menuBarHoverEnabled: Bool {
            self == .menuBarIcon || self == .both
        }

        /// 桌面常驻面板是否显示
        var desktopPanelEnabled: Bool {
            self == .desktopPanel || self == .both
        }
    }

    /// 「显示待办面板」模式（默认菜单栏图标：旧默认 hover 弹层可见、面板关）
    var todoPanelDisplayMode: TodoPanelDisplayMode {
        didSet {
            UserDefaults.standard.set(todoPanelDisplayMode.rawValue, forKey: "todoPanelDisplayMode")
            // 桌面面板档联动显隐；弹层抑制器为闭包动态读取，无需额外联动
            Task { @MainActor in
                DesktopTodoPanelManager.shared.syncVisibility()
            }
        }
    }

    /// 系统日历分类颜色
    var systemCalendarColorHex: String {
        didSet {
            UserDefaults.standard.set(systemCalendarColorHex, forKey: "systemCalendarColorHex")
        }
    }

    /// 自定义日历分类颜色
    var subscriptionCalendarColorHex: String {
        didSet {
            UserDefaults.standard.set(subscriptionCalendarColorHex, forKey: "subscriptionCalendarColorHex")
        }
    }

    /// 启动时检查更新（仅在初次启动时检查）
    var checkUpdateOnFirstLaunch: Bool {
        didSet {
            UserDefaults.standard.set(checkUpdateOnFirstLaunch, forKey: "checkUpdateOnFirstLaunch")
        }
    }

    /// 是否同步系统提醒
    var syncSystemReminders: Bool {
        didSet {
            UserDefaults.standard.set(syncSystemReminders, forKey: "syncSystemReminders")
            // 关闭时清除提醒缓存（clearRemindersCache 为 @MainActor 方法，需切换到主线程执行）
            if !syncSystemReminders {
                Task { @MainActor in
                    EventCacheService.shared.clearRemindersCache()
                }
            }
        }
    }

    /// 事项是否同步到系统日历和提醒
    var syncEventsToSystem: Bool {
        didSet {
            UserDefaults.standard.set(syncEventsToSystem, forKey: "syncEventsToSystem")
        }
    }

    /// 默认显示待办过滤模式
    var defaultFilterMode: String {
        didSet {
            UserDefaults.standard.set(defaultFilterMode, forKey: "defaultFilterMode")
        }
    }

    /// 获取 EventFilterMode 枚举值
    var defaultFilterModeEnum: EventFilterMode {
        EventFilterMode(rawValue: defaultFilterMode) ?? .thisMonth
    }

    var colorScheme: ColorScheme? {
        switch themeMode {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }

    enum ThemeMode: String, CaseIterable, Codable {
        case light = "light"
        case dark = "dark"
        case system = "system"

        var displayName: String {
            switch self {
            case .light: return "浅色"
            case .dark: return "深色"
            case .system: return "跟随系统"
            }
        }
    }

    /// 自定义格式样式
    enum CustomFormatStyle: String, CaseIterable, Codable {
        case none = "none"
        case solid = "solid"
        case stroke = "stroke"

        var displayName: String {
            switch self {
            case .none: return "无"
            case .solid: return "实心"
            case .stroke: return "描边"
            }
        }
    }

    /// 事项排序模式
    enum SortMode: String, CaseIterable {
        case `default` = "默认排序"
        case createTime = "创建时间"
        case deadline = "截止时间"
        case priority = "优先级"
        case title = "标题"
        case reminder = "系统提醒"

        var displayName: String {
            switch self {
            case .default: return "默认排序"
            // V-24：实际按 startDate 排序（缓存事件无创建时间字段），
            // 显示名改为"开始时间"使语义与行为一致；rawValue 保留兼容已持久化设置
            case .createTime: return "开始时间"
            case .deadline: return "截止时间"
            case .priority: return "优先级"
            case .title: return "标题"
            case .reminder: return "系统提醒"
            }
        }
    }

    /// 事项排序方向
    enum SortOrder: String, CaseIterable {
        case descending = "降序"
        case ascending = "升序"

        var displayName: String {
            switch self {
            case .descending: return "降序"
            case .ascending: return "升序"
            }
        }
    }

    /// 事项排序模式
    var sortMode: SortMode {
        didSet {
            UserDefaults.standard.set(sortMode.rawValue, forKey: "sortMode")
        }
    }

    /// 事项排序方向
    var sortOrder: SortOrder {
        didSet {
            UserDefaults.standard.set(sortOrder.rawValue, forKey: "sortOrder")
        }
    }

    /// 窗口是否固定（失焦不关闭）
    /// 每次启动默认不固定，运行中切换固定状态不会持久化
    var isWindowPinned: Bool = false

    private init() {
        self.launchAtLogin = UserDefaults.standard.object(forKey: "launchAtLogin") as? Bool ?? false
        self.iconStyle = IconStyle(rawValue: UserDefaults.standard.string(forKey: "iconStyleRaw") ?? "") ?? .solidDate
        self.customIconFormat = UserDefaults.standard.string(forKey: "customIconFormat") ?? "d"
        self.customFormatStyle = CustomFormatStyle(rawValue: UserDefaults.standard.string(forKey: "customFormatStyle") ?? "") ?? .none
        self.themeMode = ThemeMode(rawValue: UserDefaults.standard.string(forKey: "themeModeRaw") ?? "") ?? .system
        self.weekdayStart = UserDefaults.standard.object(forKey: "weekdayStart") as? Int ?? 2
        self.showLunarCalendar = UserDefaults.standard.object(forKey: "showLunarCalendar") as? Bool ?? true
        self.accentColorHex = UserDefaults.standard.string(forKey: "accentColorHex") ?? "#007AFF"
        self.systemCalendarColorHex = UserDefaults.standard.string(forKey: "systemCalendarColorHex") ?? "#007AFF"
        self.subscriptionCalendarColorHex = UserDefaults.standard.string(forKey: "subscriptionCalendarColorHex") ?? "#FF9500"
        self.checkUpdateOnFirstLaunch = UserDefaults.standard.object(forKey: "checkUpdateOnFirstLaunch") as? Bool ?? true
        self.syncSystemReminders = UserDefaults.standard.object(forKey: "syncSystemReminders") as? Bool ?? false
        self.syncEventsToSystem = UserDefaults.standard.object(forKey: "syncEventsToSystem") as? Bool ?? false
        self.sortMode = SortMode(rawValue: UserDefaults.standard.string(forKey: "sortMode") ?? "") ?? .default
        self.sortOrder = SortOrder(rawValue: UserDefaults.standard.string(forKey: "sortOrder") ?? "") ?? .descending
        self.defaultFilterMode = UserDefaults.standard.string(forKey: "defaultFilterMode") ?? "本月"
        self.statusBarCountdownEnabled = UserDefaults.standard.object(forKey: "statusBarCountdownEnabled") as? Bool ?? false
        // 「显示待办面板」：新键直读（默认菜单栏图标）；旧 Bool 开关键存在则迁移
        //（true→两者/false→菜单栏图标）并删除旧键，升级用户行为零回归；
        // init 内赋值不触发 didSet，迁移分支需手动持久化新键
        if UserDefaults.standard.object(forKey: "desktopTodoPanelEnabled") is Bool {
            let legacy = UserDefaults.standard.bool(forKey: "desktopTodoPanelEnabled")
            self.todoPanelDisplayMode = .fromLegacy(enabled: legacy)
            UserDefaults.standard.set(self.todoPanelDisplayMode.rawValue, forKey: "todoPanelDisplayMode")
            UserDefaults.standard.removeObject(forKey: "desktopTodoPanelEnabled")
        } else {
            self.todoPanelDisplayMode = TodoPanelDisplayMode(
                rawValue: UserDefaults.standard.string(forKey: "todoPanelDisplayMode") ?? ""
            ) ?? .menuBarIcon
        }

        // 初始化时同步一次开机启动状态（让 SMAppService 生效）
        updateLaunchAtLogin()
    }

    private func updateLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            AppLogger.settings.error("更新登录项失败: \(String(describing: error))")
        }
    }
}
