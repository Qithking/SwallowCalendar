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
            StatusBarIconManager.shared.updateIcon()
        }
    }

    var customIconFormat: String {
        didSet {
            UserDefaults.standard.set(customIconFormat, forKey: "customIconFormat")
            StatusBarIconManager.shared.updateIcon()
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
            StatusBarIconManager.shared.updateIcon()
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

    private init() {
        self.launchAtLogin = UserDefaults.standard.bool(forKey: "launchAtLogin")
        self.iconStyle = IconStyle(rawValue: UserDefaults.standard.string(forKey: "iconStyleRaw") ?? "") ?? .solidDate
        self.customIconFormat = UserDefaults.standard.string(forKey: "customIconFormat") ?? "d"
        self.themeMode = ThemeMode(rawValue: UserDefaults.standard.string(forKey: "themeModeRaw") ?? "") ?? .system
        self.weekdayStart = UserDefaults.standard.object(forKey: "weekdayStart") as? Int ?? 2
        self.showLunarCalendar = UserDefaults.standard.object(forKey: "showLunarCalendar") as? Bool ?? true
        self.accentColorHex = UserDefaults.standard.string(forKey: "accentColorHex") ?? "#007AFF"
        self.systemCalendarColorHex = UserDefaults.standard.string(forKey: "systemCalendarColorHex") ?? "#007AFF"
        self.subscriptionCalendarColorHex = UserDefaults.standard.string(forKey: "subscriptionCalendarColorHex") ?? "#FF9500"
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
