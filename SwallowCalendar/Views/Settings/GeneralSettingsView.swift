//
//  GeneralSettingsView.swift
//  SwallowCalendar
//

import SwiftUI

struct GeneralSettingsView: View {
    @Environment(AppSettings.self) private var appSettings
    @State private var customAccentColor: Color = Color(hex: AppSettings.shared.accentColorHex)

    var body: some View {
        @Bindable var settings = appSettings

        Form {
            // 开机启动
            Section("启动") {
                Toggle("开机自动启动", isOn: $settings.launchAtLogin)
                Toggle("启动时检查更新", isOn: $settings.checkUpdateOnFirstLaunch)
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
                
                // 主题色
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("主题色")
                            .font(.system(size: 12))
                        Spacer()
                        ForEach(accentColors, id: \.self) { colorHex in
                            Circle()
                                .fill(Color(hex: colorHex))
                                .frame(width: 22, height: 22)
                                .overlay(
                                    Circle()
                                        .stroke(appSettings.accentColorHex == colorHex ? Color.primary : Color.clear, lineWidth: 2)
                                )
                                .onTapGesture {
                                    settings.accentColorHex = colorHex
                                }
                        }
                    }
                    
                    HStack {
                        Text("自定义颜色")
                            .font(.system(size: 12))
                        Spacer()
                        ColorPicker("", selection: $customAccentColor)
                            .labelsHidden()
                            .frame(width: 30)
                            .onChange(of: customAccentColor) { _, newColor in
                                settings.accentColorHex = newColor.toHex() ?? settings.accentColorHex
                            }
                    }
                }

                // 星期起始日
                Picker("星期起始日", selection: $settings.weekdayStart) {
                    Text("周日").tag(1)
                    Text("周一").tag(2)
                }

                // 默认显示待办过滤
                Picker("默认显示待办", selection: $settings.defaultFilterMode) {
                    ForEach(EventFilterMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode.rawValue)
                    }
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

    private let iconColors = [
        "#FF3B30", // 红色
        "#FF9500", // 橙色
        "#FFCC00", // 黄色
        "#34C759", // 绿色
        "#007AFF", // 蓝色
        "#AF52DE", // 紫色
        "#FF2D55", // 粉色
        "#8E8E93"  // 灰色
    ]
    
    private let accentColors = [
        "#FF3B30", // 红色
        "#FF9500", // 橙色
        "#FFCC00", // 黄色
        "#34C759", // 绿色
        "#007AFF", // 蓝色
        "#5856D6", // 靛蓝色
        "#AF52DE", // 紫色
        "#FF2D55"  // 粉色
    ]
}

// MARK: - Color to Hex Extension

extension Color {
    func toHex() -> String? {
        let nsColor = NSColor(self)
        guard let rgbColor = nsColor.usingColorSpace(.sRGB) else { return nil }
        let r = Int(rgbColor.redComponent * 255)
        let g = Int(rgbColor.greenComponent * 255)
        let b = Int(rgbColor.blueComponent * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
