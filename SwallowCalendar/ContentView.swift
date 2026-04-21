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
    @State private var icsService = ICSService.shared
    @State private var refreshTrigger = false  // 用于触发视图刷新
    @State private var isSyncing = false  // 同步状态
    @State private var shouldSyncOnAppear = false  // 是否在显示时同步
    @State private var hasInitialized = false  // 是否已初始化
    
    // 用于强制视图响应主题色变化
    @State private var accentColor: Color = Color(hex: AppSettings.shared.accentColorHex)

    var body: some View {
        VStack(spacing: 0) {
            // 日历区域
            CalendarGridView(
                selectedDate: $selectedDate,
                calendarService: calendarService,
                icsService: icsService,
                customSources: customSources,
                calendarPreferences: calendarPreferences
            )

            Divider()

            // 事项区域（占满剩余空间）
            EventPanelView(
                selectedDate: $selectedDate,
                calendarService: calendarService,
                calendarPreferences: calendarPreferences
            )
            .frame(maxHeight: .infinity)

            Divider()

            // 工具栏
            toolbar
        }
        .preferredColorScheme(appSettings.colorScheme)
        .tint(accentColor)
        .onChange(of: appSettings.accentColorHex) { _, newColor in
            accentColor = Color(hex: newColor)
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            // 从非活跃状态切换到活跃状态时，说明是用户点击了菜单栏图标
            if oldPhase != .active && newPhase == .active {
                shouldSyncOnAppear = true
            }
        }
        .task(id: shouldSyncOnAppear ? "sync" : "idle") {
            // 首次启动或点击菜单栏图标时同步
            if !hasInitialized || shouldSyncOnAppear {
                await initializeServices()
                await syncCalendarEvents()
                hasInitialized = true
                shouldSyncOnAppear = false
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
        // 请求日历和提醒权限（同时请求，只弹一次授权框）
        if calendarService.authorizationStatus == .notDetermined {
            _ = await calendarService.requestAccess()
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

        // 预加载订阅日历数据
        await icsService.preloadSubscriptions(sources: customSources)
    }
    
    /// 后台同步日历事件到本地缓存
    private func syncCalendarEvents() async {
        guard calendarService.authorizationStatus == .fullAccess else { return }

        let enabledCals = calendarService.enabledCalendars(preferences: calendarPreferences)
        await calendarService.cacheService.syncEvents(from: calendarService, calendars: enabledCals)

        // 同步系统提醒（如果开启）
        if appSettings.syncSystemReminders && calendarService.reminderAuthorizationStatus == .fullAccess {
            await calendarService.cacheService.syncReminders(from: calendarService)
        }

        // 同步完成后刷新视图
        refreshTrigger.toggle()
    }
    
    /// 手动同步日历事件
    private func manualSyncCalendarEvents() async {
        guard !isSyncing else { return }

        isSyncing = true

        // 检查日历权限
        if calendarService.authorizationStatus != .fullAccess {
            await MainActor.run {
                showAlert(title: "同步失败", message: "日历权限不足，请在系统设置中授权", style: .warning)
            }
            isSyncing = false
            return
        }

        do {
            let enabledCals = calendarService.enabledCalendars(preferences: calendarPreferences)
            await calendarService.cacheService.syncEvents(from: calendarService, calendars: enabledCals)
            refreshTrigger.toggle()
            await MainActor.run {
                showAlert(title: "同步成功", message: "日历数据同步完成", style: .informational)
            }
        } catch {
            await MainActor.run {
                showAlert(title: "同步失败", message: error.localizedDescription, style: .critical)
            }
        }

        isSyncing = false
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
