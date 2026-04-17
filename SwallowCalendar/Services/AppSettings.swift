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
