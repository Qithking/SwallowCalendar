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
            // 启动
            Section("启动") {
                Toggle("开机自动启动", isOn: $settings.launchAtLogin)
                    .toggleStyle(.switch)
                Toggle("启动时检查更新", isOn: $settings.checkUpdateOnFirstLaunch)
                    .toggleStyle(.switch)
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
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    
                    // 自定义格式样式选项
                    Picker("自定义图标样式", selection: $settings.customFormatStyle) {
                        ForEach(AppSettings.CustomFormatStyle.allCases, id: \.self) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .disabled(appSettings.customIconFormat.isEmpty)
                }

                // D2：菜单栏倒计时徽标开关
                Toggle("显示最近待办倒计时", isOn: $settings.statusBarCountdownEnabled)
                    .toggleStyle(.switch)
                    .help("在菜单栏显示最近未完成待办事项的剩余时间，事项变更后即时刷新；徽标外观跟随「菜单栏图标」样式（实心/描边/无背景）")

                // 主题
                Picker("主题", selection: $settings.themeMode) {
                    ForEach(AppSettings.ThemeMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                // 主题色
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text("主题色")
                            .font(.system(size: 12))
                        Spacer()
                        ForEach(accentColors, id: \.self) { colorHex in
                            Circle()
                                .fill(Color(hex: colorHex))
                                .frame(width: 20, height: 20)
                                .overlay(
                                    // 选中态：外圈描边环（与编辑面板颜色选中质感一致）
                                    Circle()
                                        .strokeBorder(Color.primary.opacity(0.85), lineWidth: 1.5)
                                        .frame(width: 26, height: 26)
                                        .opacity(appSettings.accentColorHex == colorHex ? 1 : 0)
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
            }

            // 显示选项
            Section("显示选项") {
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

                // 显示农历
                Toggle("显示农历", isOn: $settings.showLunarCalendar)
                    .toggleStyle(.switch)

                // 显示待办面板（需求：四态下拉，顺序按需求原话——菜单栏图标控制
                // hover 弹层，桌面面板控制常驻面板，两者=现有逻辑）
                Picker("显示待办面板", selection: $settings.todoPanelDisplayMode) {
                    ForEach([AppSettings.TodoPanelDisplayMode.none,
                             .menuBarIcon,
                             .desktopPanel,
                             .both], id: \.self) { mode in
                        Text(mode.displayTitle).tag(mode)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // 预览格式化器缓存：格式未变化时复用（body 每次求值都会调用本计算属性）
    // V-25：标注 @MainActor 隔离——View 是 struct，非隔离 static var 在并发下有数据竞争；
    // 访问方 body 与预览计算均在主线程，隔离到 MainActor 即可
    @MainActor
    private static var previewFormatCache: (format: String, formatter: DateFormatter)?

    private var customFormatPreview: String {
        let format = appSettings.customIconFormat
        let formatter: DateFormatter
        if let cache = Self.previewFormatCache, cache.format == format {
            formatter = cache.formatter
        } else {
            formatter = DateFormatter()
            formatter.dateFormat = format
            Self.previewFormatCache = (format, formatter)
        }
        return formatter.string(from: Date())
    }

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
