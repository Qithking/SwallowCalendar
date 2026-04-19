//
//  CalendarSettingsView.swift
//  SwallowCalendar
//

import SwiftUI
import EventKit
import SwiftData

struct CalendarSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppSettings.self) private var appSettings
    @Query private var calendarPreferences: [CalendarPreference]
    @Query private var customSources: [CustomCalendarSource]
    @State private var calendarService = CalendarService.shared

    @State private var newSourceName = ""
    @State private var newSourceURL = ""
    @State private var saveStatus: String = "就绪"
    @State private var showingSaveConfirmation = false

    var body: some View {
        @Bindable var settings = appSettings

        Form {
            // 显示选项
            Section("显示选项") {
                Toggle("显示农历", isOn: $settings.showLunarCalendar)
            }

            // 日历颜色
            Section("日历颜色") {
                HStack {
                    Text("系统日历")
                        .font(.system(size: 12))
                    Spacer()
                    ColorPicker("", selection: Binding(
                        get: { Color(hex: settings.systemCalendarColorHex) },
                        set: { settings.systemCalendarColorHex = $0.toHex() ?? settings.systemCalendarColorHex }
                    ))
                }

                HStack {
                    Text("订阅日历")
                        .font(.system(size: 12))
                    Spacer()
                    ColorPicker("", selection: Binding(
                        get: { Color(hex: settings.subscriptionCalendarColorHex) },
                        set: { settings.subscriptionCalendarColorHex = $0.toHex() ?? settings.subscriptionCalendarColorHex }
                    ))
                }
            }

            // 日历分类
            Section("系统日历") {
                if calendarPreferences.isEmpty && calendarService.calendars.isEmpty {
                    Text("正在加载...")
                        .foregroundColor(.secondary)
                        .font(.system(size: 11))
                } else if calendarService.calendars.isEmpty {
                    Text("暂无可用的日历")
                        .foregroundColor(.secondary)
                        .font(.system(size: 11))
                } else {
                    ForEach(calendarService.calendars, id: \.calendarIdentifier) { cal in
                        calendarPreferenceRow(for: cal)
                    }
                }
            }

            // 订阅日历
            Section("订阅日历") {
                if customSources.isEmpty {
                    Text("暂无订阅日历")
                        .foregroundColor(.secondary)
                        .font(.system(size: 11))
                } else {
                    ForEach(customSources, id: \.id) { source in
                        subscriptionSourceRow(for: source)
                    }
                }

                // 添加新源
                HStack(spacing: 8) {
                    TextField("名称", text: $newSourceName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    TextField("ICS URL", text: $newSourceURL)
                        .textFieldStyle(.roundedBorder)
                    Button("添加") {
                        addCustomSource()
                    }
                    .disabled(newSourceName.isEmpty || newSourceURL.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .tint(Color(hex: appSettings.accentColorHex))
        .task {
            calendarService.loadCalendars()
            print("[CalendarSettings] 视图加载，日历偏好: \(calendarPreferences.count), 订阅源: \(customSources.count)")
        }
        .onDisappear {
            // 窗口关闭时确保保存所有更改
            saveAllChanges()
        }
    }

    // MARK: - 系统日历行

    @ViewBuilder
    private func calendarPreferenceRow(for cal: EKCalendar) -> some View {
        let calID = cal.calendarIdentifier
        let pref = calendarPreferences.first { $0.calendarID == calID }

        HStack(spacing: 6) {
            // 启用开关
            Toggle("", isOn: Binding(
                get: { pref?.isEnabled ?? false },
                set: { newValue in
                    updateCalendarEnabled(calendarID: calID, isEnabled: newValue)
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .scaleEffect(0.7)

            // 日历颜色指示
            Circle()
                .fill(Color(cgColor: cal.cgColor))
                .frame(width: 8, height: 8)

            // 日历名称
            Text(cal.title)
                .font(.system(size: 12))
                .lineLimit(1)

            Spacer()

            // 重要复选框
            CheckBox(title: "重要", isChecked: Binding(
                get: { pref?.isImportant ?? false },
                set: { newValue in
                    updateCalendarImportant(calendarID: calID, isImportant: newValue)
                }
            ))
        }
    }

    // MARK: - 订阅日历行

    @ViewBuilder
    private func subscriptionSourceRow(for source: CustomCalendarSource) -> some View {
        let sourceID = source.id

        HStack(spacing: 6) {
            // 启用开关
            Toggle("", isOn: Binding(
                get: { source.isEnabled },
                set: { newValue in
                    updateSubscriptionEnabled(id: sourceID, isEnabled: newValue)
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .scaleEffect(0.7)

            // 名称
            Text(source.name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .frame(minWidth: 60, maxWidth: 80)

            // URL
            Text(source.icsURL)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            // 重要复选框
            CheckBox(title: "重要", isChecked: Binding(
                get: { source.isImportant },
                set: { newValue in
                    updateSubscriptionImportant(id: sourceID, isImportant: newValue)
                }
            ))

            // 删除按钮
            Button {
                deleteCustomSource(id: sourceID)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 数据操作

    private func updateCalendarEnabled(calendarID: String, isEnabled: Bool) {
        print("[CalendarSettings] 更新日历启用状态: \(calendarID) = \(isEnabled)")
        
        if let pref = calendarPreferences.first(where: { $0.calendarID == calendarID }) {
            pref.isEnabled = isEnabled
        } else {
            let pref = CalendarPreference(calendarID: calendarID, isEnabled: isEnabled, isImportant: false)
            modelContext.insert(pref)
        }
        
        saveWithStatus()
    }

    private func updateCalendarImportant(calendarID: String, isImportant: Bool) {
        print("[CalendarSettings] 更新日历重要状态: \(calendarID) = \(isImportant)")
        
        // 如果设置为重点，先取消其他所有日历的重点标识
        if isImportant {
            clearAllImportantSources()
        }
        
        if let pref = calendarPreferences.first(where: { $0.calendarID == calendarID }) {
            pref.isImportant = isImportant
        } else {
            let pref = CalendarPreference(calendarID: calendarID, isEnabled: true, isImportant: isImportant)
            modelContext.insert(pref)
        }
        
        saveWithStatus()
    }

    private func updateSubscriptionEnabled(id: PersistentIdentifier, isEnabled: Bool) {
        print("[CalendarSettings] 更新订阅源启用状态: \(id) = \(isEnabled)")
        
        if let source = customSources.first(where: { $0.id == id }) {
            source.isEnabled = isEnabled
        }
        
        saveWithStatus()
    }

    private func updateSubscriptionImportant(id: PersistentIdentifier, isImportant: Bool) {
        print("[CalendarSettings] 更新订阅源重要状态: \(id) = \(isImportant)")
        
        // 如果设置为重点，先取消其他所有日历的重点标识
        if isImportant {
            clearAllImportantSources()
        }
        
        if let source = customSources.first(where: { $0.id == id }) {
            source.isImportant = isImportant
        }
        
        saveWithStatus()
    }

    private func clearAllImportantSources() {
        print("[CalendarSettings] 清除所有重要标记")
        
        for pref in calendarPreferences {
            pref.isImportant = false
        }
        for source in customSources {
            source.isImportant = false
        }
    }

    private func addCustomSource() {
        print("[CalendarSettings] 添加新订阅源: \(newSourceName)")
        
        let source = CustomCalendarSource(
            name: newSourceName,
            icsURL: newSourceURL,
            isEnabled: false,
            isImportant: false
        )
        modelContext.insert(source)
        
        saveWithStatus()
        
        newSourceName = ""
        newSourceURL = ""
    }

    private func deleteCustomSource(id: PersistentIdentifier) {
        print("[CalendarSettings] 删除订阅源: \(id)")
        
        if let source = customSources.first(where: { $0.id == id }) {
            modelContext.delete(source)
        }
        
        saveWithStatus()
    }

    private func saveWithStatus() {
        do {
            try modelContext.save()
            saveStatus = "已保存 \(Date().formatted(date: .omitted, time: .shortened))"
        } catch {
            saveStatus = "保存失败"
            print("[CalendarSettings] 保存失败: \(error)")
        }
    }

    private func saveAllChanges() {
        try? modelContext.save()
    }
}

/// 自定义 CheckBox 组件
struct CheckBox: View {
    let title: String
    @Binding var isChecked: Bool

    var body: some View {
        Button {
            isChecked.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12))
                    .foregroundColor(isChecked ? Color(hex: AppSettings.shared.accentColorHex) : .secondary)
                Text(title)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}
