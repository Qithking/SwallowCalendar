//
//  GeneralSettingsView.swift
//  SwallowCalendar
//

import SwiftUI

struct GeneralSettingsView: View {
    @Environment(AppSettings.self) private var appSettings

    var body: some View {
        @Bindable var settings = appSettings

        Form {
            // 开机启动
            Section("启动") {
                Toggle("开机自动启动", isOn: $settings.launchAtLogin)
            }

            // 外观
            Section("外观") {
                // 菜单栏图标
                Picker("菜单栏图标", selection: $settings.iconStyle) {
                    ForEach(IconStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }

                // 自定义格式输入
                if appSettings.iconStyle == .customFormat {
                    TextField("自定义格式", text: $settings.customIconFormat)
                        .textFieldStyle(.roundedBorder)
                        .help("支持 Unicode TR35 日期格式，如: d (日), M/d (月/日), MM-dd 等")
                    Text("预览: \(customFormatPreview)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                // 主题
                Picker("主题", selection: $settings.themeMode) {
                    ForEach(AppSettings.ThemeMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                // 星期起始日
                Picker("星期起始日", selection: $settings.weekdayStart) {
                    Text("周日").tag(1)
                    Text("周一").tag(2)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var customFormatPreview: String {
        let formatter = DateFormatter()
        formatter.dateFormat = appSettings.customIconFormat
        return formatter.string(from: Date())
    }
}
