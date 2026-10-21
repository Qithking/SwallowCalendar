//
//  ContentView.swift
//  SwallowCalendar
//
//  Created by thking on 2026/4/17.
//

import SwiftUI
import SwiftData
import os
import EventKit
import AppKit

struct ContentView: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.modelContext) private var modelContext
    @Query private var customSources: [CustomCalendarSource]
    @Query private var calendarPreferences: [CalendarPreference]

    @State private var selectedDate = Date()
    // V-32：CalendarService.shared 是单例引用，语义为常量依赖，用 let 而非 @State（@State 用于值语义状态）
    private let calendarService = CalendarService.shared
    @State private var eventsChangedSyncTask: Task<Void, Never>?  // V-1：事件变更防抖同步任务
    
    // V-18：直接读 appSettings 主题色，替代 @State 复制 + onChange 同步
    private var accentColor: Color { Color(hex: appSettings.accentColorHex) }

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
                        // V-1：连续增删改（批量完成/删除等）会触发多次全量同步，
                        // 先取消上一个防抖任务，静默 2 秒无新变更后只执行一次同步，避免同步风暴
                        eventsChangedSyncTask?.cancel()
                        eventsChangedSyncTask = Task {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            guard !Task.isCancelled else { return }
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
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CalendarCacheCleared"))) { _ in
            // V-6：缓存被清空后重新全量同步，恢复本地数据
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

        // 请求日历权限（S-7：按需拆分——提醒同步默认关闭，关闭时仅请求日历权限，
        // 不无条件索要提醒 fullAccess）
        let syncReminders = appSettings.syncSystemReminders
        var reminderGranted = calendarService.reminderAuthorizationStatus == .fullAccess
        if calendarService.authorizationStatus == .notDetermined {
            let result = await calendarService.requestAccess(requestReminders: syncReminders)
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
        // N-5：默认订阅源仅首次启动插入一次（UserDefaults 标记）——原 isEmpty 判断会在
        // 用户删光全部订阅源后重启时复活默认源，导致删除无法持久生效
        let seedKey = "hasSeededDefaultCalendarSource"
        if !UserDefaults.standard.bool(forKey: seedKey) {
            let defaultSource = CustomCalendarSource(
                name: "重要日历",
                icsURL: "https://yangh9.github.io/ChinaCalendar/cal_holiday.ics",
                isEnabled: false,
                isImportant: false
            )
            modelContext.insert(defaultSource)
            do {
                // 落库成功才写 seed 标记：save 失败时标记仍写入会导致默认源永久不再插入
                try modelContext.save()
                UserDefaults.standard.set(true, forKey: seedKey)
            } catch {
                AppLogger.settings.error("默认订阅源首次插入失败（下次启动重试）: \(error.localizedDescription)")
            }
        }

        // 在 mainContext 注入后启动后台同步，确保使用同一 ModelContext
        await BackgroundSyncService.shared.start()
        
        // 同步完成后检查过期事项，确保启动时始终提示
        await ReminderAlertService.shared.checkExpiredEvents()
        
        // 清理过期的 ICS 缓存文件
        ICSService.shared.cleanupExpiredCache()
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
}
