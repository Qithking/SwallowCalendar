//
//  AppSettings.swift
//  SwallowCalendar
//

import Foundation
import ServiceManagement
import SwiftUI

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
            // 关闭时清除提醒缓存
            if !syncSystemReminders {
                EventCacheService.shared.clearRemindersCache()
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
            case .createTime: return "创建时间"
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
            print("Failed to update login item: \(error)")
        }
    }
}
