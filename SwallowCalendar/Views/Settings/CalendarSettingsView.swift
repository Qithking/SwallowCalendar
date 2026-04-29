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
    @State private var isRefreshing = false
    @State private var refreshSuccess = false

    var body: some View {
        @Bindable var settings = appSettings

        Form {
            // 系统提醒
            Section("同步设置") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("系统提醒同步至应用", isOn: $settings.syncSystemReminders)
                        .toggleStyle(.switch)
                    
                    Text("将系统提醒应用中的待办事项同步到待办列表中")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    
                    // 提醒权限状态提示
                    if settings.syncSystemReminders {
                        HStack(spacing: 6) {
                            let status = CalendarService.shared.reminderAuthorizationStatus
                            switch status {
                            case .notDetermined:
                                Text("需要授权访问提醒")
                                    .font(.system(size: 10))
                                    .foregroundColor(.orange)
                            case .restricted, .denied:
                                Text("权限被拒绝，点击前往设置开启")
                                    .font(.system(size: 10))
                                    .foregroundColor(.red)
                                Button("前往设置") {
                                    openReminderSettings()
                                }
                                .font(.system(size: 10))
                                .buttonStyle(.plain)
                                .foregroundColor(.blue)
                            case .fullAccess:
                                Text("已授权")
                                    .font(.system(size: 10))
                                    .foregroundColor(.green)
                            case .writeOnly:
                                Text("仅写入权限")
                                    .font(.system(size: 10))
                                    .foregroundColor(.orange)
                            @unknown default:
                                EmptyView()
                            }
                        }
                    }
                }
                
                
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("应用事项同步至系统", isOn: $settings.syncEventsToSystem)
                        .toggleStyle(.switch)
                    
                    Text("开启后，事项的增删改都与系统日历和提醒同步；关闭后，仅当前应用内的数据增删改")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    
                    if settings.syncEventsToSystem {
                        HStack(spacing: 6) {
                            let status = CalendarService.shared.authorizationStatus
                            switch status {
                            case .notDetermined:
                                Text("需要授权访问日历")
                                    .font(.system(size: 10))
                                    .foregroundColor(.orange)
                            case .restricted, .denied:
                                Text("权限被拒绝，点击前往设置开启")
                                    .font(.system(size: 10))
                                    .foregroundColor(.red)
                                Button("前往设置") {
                                    openCalendarSettings()
                                }
                                .font(.system(size: 10))
                                .buttonStyle(.plain)
                                .foregroundColor(.blue)
                            case .fullAccess:
                                Text("已授权")
                                    .font(.system(size: 10))
                                    .foregroundColor(.green)
                            case .writeOnly:
                                Text("仅写入权限")
                                    .font(.system(size: 10))
                                    .foregroundColor(.orange)
                            @unknown default:
                                EmptyView()
                            }
                        }
                    }
                }
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
            Section {
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
            } header: {
                HStack {
                    Text("系统日历")
                    Spacer()
                    Button {
                        refreshSystemCalendars()
                    } label: {
                        Image(systemName: refreshSuccess ? "checkmark.circle.fill" : "arrow.clockwise")
                            .font(.system(size: 12))
                            .foregroundColor(refreshSuccess ? .green : .primary)
                    }
                    .buttonStyle(.plain)
                    .disabled(isRefreshing || refreshSuccess)
                    .help("刷新日历数据")
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
                HStack(spacing: 6) {
                    Text("名称")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    TextField("", text: $newSourceName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Text("ICS URL")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    TextField("", text: $newSourceURL)
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
        }
        .onDisappear {
            // 窗口关闭时确保保存所有更改
            saveAllChanges()
        }
        .alert("刷新失败", isPresented: $showingSaveConfirmation) {
            Button("确定", role: .cancel) {}
        } message: {
            Text("刷新失败请重启应用后再试")
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
        if let pref = calendarPreferences.first(where: { $0.calendarID == calendarID }) {
            pref.isEnabled = isEnabled
        } else {
            let pref = CalendarPreference(calendarID: calendarID, isEnabled: isEnabled, isImportant: false)
            modelContext.insert(pref)
        }
        
        saveWithStatus()
        NotificationCenter.default.post(name: NSNotification.Name("SystemCalendarPreferencesChanged"), object: nil)
    }

    private func updateCalendarImportant(calendarID: String, isImportant: Bool) {
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
        NotificationCenter.default.post(name: NSNotification.Name("SystemCalendarPreferencesChanged"), object: nil)
    }

    private func updateSubscriptionEnabled(id: PersistentIdentifier, isEnabled: Bool) {
        if let source = customSources.first(where: { $0.id == id }) {
            source.isEnabled = isEnabled
        }
        
        saveWithStatus()
        NotificationCenter.default.post(name: NSNotification.Name("SubscriptionSourcesChanged"), object: nil)
    }

    private func updateSubscriptionImportant(id: PersistentIdentifier, isImportant: Bool) {
        // 如果设置为重点，先取消其他所有日历的重点标识
        if isImportant {
            clearAllImportantSources()
        }
        
        if let source = customSources.first(where: { $0.id == id }) {
            source.isImportant = isImportant
        }
        
        saveWithStatus()
        NotificationCenter.default.post(name: NSNotification.Name("SubscriptionSourcesChanged"), object: nil)
    }

    private func clearAllImportantSources() {
        for pref in calendarPreferences {
            pref.isImportant = false
        }
        for source in customSources {
            source.isImportant = false
        }
    }

    private func addCustomSource() {
        let source = CustomCalendarSource(
            name: newSourceName,
            icsURL: newSourceURL,
            isEnabled: false,
            isImportant: false
        )
        modelContext.insert(source)
        
        saveWithStatus()
        NotificationCenter.default.post(name: NSNotification.Name("SubscriptionSourcesChanged"), object: nil)
        
        newSourceName = ""
        newSourceURL = ""
    }

    private func deleteCustomSource(id: PersistentIdentifier) {
        if let source = customSources.first(where: { $0.id == id }) {
            modelContext.delete(source)
        }
        
        saveWithStatus()
        NotificationCenter.default.post(name: NSNotification.Name("SubscriptionSourcesChanged"), object: nil)
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

    private func refreshSystemCalendars() {
        guard !isRefreshing else { return }
        isRefreshing = true
        refreshSuccess = false

        calendarService.manualSync(preferences: calendarPreferences) { success, message in
            isRefreshing = false
            if success {
                refreshSuccess = true
                calendarService.loadCalendars()
                // 3秒后恢复
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    refreshSuccess = false
                }
            } else {
                saveStatus = message
                showingSaveConfirmation = true
            }
        }
    }

    /// 打开系统设置中的提醒权限页面
    private func openReminderSettings() {
        // 使用正确的 URL scheme，先检查是否可以打开
        if let url = URL(string: "x-apple.systempreferences://com.apple.preference.security?Privacy_Reminders") {
            if NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
                NSWorkspace.shared.open(url)
            }
        }
    }
    
    /// 打开系统设置中的日历权限页面
    private func openCalendarSettings() {
        // 使用正确的 URL scheme，先检查是否可以打开
        if let url = URL(string: "x-apple.systempreferences://com.apple.preference.security?Privacy_Calendars") {
            if NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
                NSWorkspace.shared.open(url)
            }
        }
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
