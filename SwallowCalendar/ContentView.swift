//
//  ContentView.swift
//  SwallowCalendar
//
//  Created by thking on 2026/4/17.
//

import SwiftUI
import SwiftData
import EventKit
import AppKit

struct ContentView: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query private var customSources: [CustomCalendarSource]
    @Query private var calendarPreferences: [CalendarPreference]

    @State private var selectedDate = Date()
    @State private var calendarService = CalendarService.shared
    @State private var isSyncing = false  // 同步状态
    
    // 用于强制视图响应主题色变化
    @State private var accentColor: Color = Color(hex: AppSettings.shared.accentColorHex)

    var body: some View {
        ZStack {
            // 系统级毛玻璃背景
            VisualEffectView()
                .ignoresSafeArea()
            
            // 主内容
            VStack(spacing: 0) {
                // 日历区域
                CalendarGridView(
                    selectedDate: $selectedDate,
                    calendarService: calendarService,
                    customSources: customSources,
                    calendarPreferences: calendarPreferences
                )

                Divider()

                // 事项区域（占满剩余空间）
                EventPanelView(
                    selectedDate: $selectedDate,
                    calendarService: calendarService,
                    calendarPreferences: calendarPreferences,
                    onEventsChanged: {
                        Task {
                            await BackgroundSyncService.shared.syncOnce()
                        }
                    }
                )
                .frame(maxHeight: .infinity)

                Divider()

                // 工具栏
                toolbar
            }
        }
        .cornerRadius(Popup.totalCornerRadius)
        .preferredColorScheme(appSettings.colorScheme)
        .tint(accentColor)
        .task {
            await initializeServices()
        }
        .onChange(of: appSettings.accentColorHex) { _, newColor in
            accentColor = Color(hex: newColor)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SystemCalendarPreferencesChanged"))) { _ in
            // 系统日历偏好变化时，触发系统日历同步
            Task {
                await BackgroundSyncService.shared.syncOnce()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SubscriptionSourcesChanged"))) { _ in
            Task {
                await BackgroundSyncService.shared.syncOnce()
            }
        }
        .onChange(of: appSettings.syncSystemReminders) { _, _ in
            Task {
                await BackgroundSyncService.shared.syncOnce()
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack {
            // 设置按钮
            Button {
                SettingsWindowManager.shared.openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .help("设置")
            
            // 同步按钮
            Button {
                Task {
                    await BackgroundSyncService.shared.syncOnce()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .help("同步数据")
            
            // 固定窗口按钮
            Button {
                appSettings.isWindowPinned.toggle()
            } label: {
                Image(systemName: appSettings.isWindowPinned ? "pin.fill" : "pin")
                    .font(.system(size: 13))
                    .foregroundColor(appSettings.isWindowPinned ? accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(appSettings.isWindowPinned ? "取消固定窗口" : "固定窗口")

            Spacer()

            // 退出按钮
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .help("退出应用")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.clear)
    }

    // MARK: - Services Init

    private func initializeServices() async {
        // 将环境 ModelContext 注入服务层，确保服务写入与 @Query 读取使用同一上下文
        EventCacheService.shared.setMainContext(modelContext)
        BackgroundSyncService.shared.setMainContext(modelContext)

        // 请求日历和提醒权限（同时请求，只弹一次授权框）
        var reminderGranted = calendarService.reminderAuthorizationStatus == .fullAccess
        if calendarService.authorizationStatus == .notDetermined {
            let result = await calendarService.requestAccess()
            reminderGranted = result.reminder
        }

        // 若提醒授权被拒绝，弹窗引导用户开启
        if !reminderGranted && calendarService.reminderAuthorizationStatus == .denied {
            await MainActor.run {
                showReminderAuthAlert()
            }
        }

        calendarService.loadCalendars()

        // 初始化默认自定义日历
        if customSources.isEmpty {
            let defaultSource = CustomCalendarSource(
                name: "重要日历",
                icsURL: "https://yangh9.github.io/ChinaCalendar/cal_holiday.ics",
                isEnabled: false,
                isImportant: false
            )
            modelContext.insert(defaultSource)
            try? modelContext.save()
        }

        // 在 mainContext 注入后启动后台同步，确保使用同一 ModelContext
        await BackgroundSyncService.shared.start()
    }

    /// 弹窗引导用户去系统设置开启提醒权限
    private func showReminderAuthAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "需要提醒权限"
        alert.informativeText = "请在系统设置中开启「提醒」权限，以便同步系统提醒事项。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "去开启")
        alert.addButton(withTitle: "忽略")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            calendarService.openReminderSettings()
        }
    }

    private func showAlert(title: String, message: String, style: NSAlert.Style) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: "确定")
        alert.runModal()
    }
}
