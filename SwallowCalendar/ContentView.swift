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
    // CalendarService.shared 是单例引用，语义为常量依赖，用 let 而非 @State（@State 用于值语义状态）
    private let calendarService = CalendarService.shared
    @State private var eventsChangedSyncTask: Task<Void, Never>?  // 事件变更防抖同步任务
    @State private var syncState: SyncFeedbackState = .idle  // 同步按钮反馈状态

    // 同步按钮反馈三态：同步中菊花 / 成功绿勾 / 失败红 X（附弹窗），终态 2 秒后复原
    private enum SyncFeedbackState {
        case idle
        case syncing
        case success
        case failure(String)
    }
    
    // 直接读 appSettings 主题色，无需 @State 复制 + onChange 同步
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
                .layoutPriority(1)  // 布局锁定：VStack 空间不足时日历保持固有尺寸不被压缩

                Divider()

                // 事项区域（占满剩余空间）
                EventPanelView(
                    selectedDate: $selectedDate,
                    calendarService: calendarService,
                    calendarPreferences: calendarPreferences,
                    onEventsChanged: {
                        // 连续增删改（批量完成/删除等）会触发多次全量同步，
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
                    .layoutPriority(1)  // 布局锁定：表单展开时不被挤出可见区域
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
            // 缓存被清空后重新全量同步，恢复本地数据
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
            
            // 同步按钮（三态反馈：点击菊花 → 成功绿勾 / 失败红 X + 弹窗，终态 2 秒后复原）
            Button {
                // 仅空闲态可触发：同步中/结果展示中忽略连点
                guard case .idle = syncState else { return }
                syncState = .syncing
                Task {
                    let start = ContinuousClock.now
                    let failure = await BackgroundSyncService.shared.syncOnce()
                    // 最短展示 0.6s：同步极快完成时状态变化仍可感知（防闪烁无感知）
                    let elapsed = start.duration(to: .now)
                    if elapsed < .seconds(0.6) {
                        try? await Task.sleep(for: .seconds(0.6) - elapsed)
                    }
                    if let failure {
                        syncState = .failure(failure)
                        // 弹出错误说明（模态弹窗，关闭后红 X 保留 2 秒再复原）
                        NSApp.activate(ignoringOtherApps: true)
                        let alert = NSAlert()
                        alert.messageText = "同步失败"
                        alert.informativeText = failure
                        alert.alertStyle = .critical
                        alert.addButton(withTitle: "好的")
                        alert.runModal()
                        try? await Task.sleep(for: .seconds(2))
                    } else {
                        syncState = .success
                        try? await Task.sleep(for: .seconds(2))
                    }
                    syncState = .idle
                }
            } label: {
                Group {
                    switch syncState {
                    case .idle:
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13))
                    case .syncing:
                        ProgressView()
                            .controlSize(.small)
                    case .success:
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 13))
                            .foregroundColor(.green)
                    case .failure:
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 13))
                            .foregroundColor(.red)
                    }
                }
                .frame(width: 16, height: 16)  // 固定占位，切换不跳动
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

        // 请求日历权限（按需拆分——提醒同步默认关闭，关闭时仅请求日历权限，
        // 不无条件索要提醒 fullAccess）
        let syncReminders = appSettings.syncSystemReminders
        var reminderGranted = calendarService.reminderAuthorizationStatus == .fullAccess
        if calendarService.authorizationStatus == .notDetermined {
            let result = await calendarService.requestAccess(requestReminders: syncReminders)
            reminderGranted = result.reminder
        } else if CalendarService.shouldRequestReminderAccess(
            syncEnabled: syncReminders,
            reminderAuth: calendarService.reminderAuthorizationStatus
        ) {
            // reminder-auth-prompt：日历已授权而提醒从未询问时，原逻辑整体跳过导致
            // 权限永久卡在 notDetermined；开关已开启视为明确使用意图，主动补弹系统授权
            reminderGranted = await calendarService.requestReminderAccess()
        }

        // 若提醒授权被拒绝，弹窗引导用户开启
        if !reminderGranted && calendarService.reminderAuthorizationStatus == .denied {
            await MainActor.run {
                showReminderAuthAlert()
            }
        }

        calendarService.loadCalendars()

        // 初始化默认自定义日历（seed-dedupe 双保险）
        // 默认订阅源由 UserDefaults 标记 + 库级 URL 判重共同决定是否插入：
        // 标记可能因 cfprefsd 与磁盘 plist 脱节被读为 false（仅靠标记曾造成重复 seed）；
        // 用户删光全部订阅源后（标记 true）重启不会复活默认源，删除可持久生效
        let seedKey = "hasSeededDefaultCalendarSource"
        do {
            let allSources = try CacheFetch.throwing(
                FetchDescriptor<CustomCalendarSource>(),
                in: modelContext,
                operation: "订阅源全量读取"
            )

            // 历史重复清理：同 URL 保留启用/重要优先的一条（seed-dedupe）
            let duplicates = CustomCalendarSource.duplicatesToRemove(allSources)
            var seedChanges = false
            if !duplicates.isEmpty {
                duplicates.forEach { modelContext.delete($0) }
                seedChanges = true
                AppLogger.settings.info("启动清理重复订阅源: \(duplicates.count) 条")
            }

            if CustomCalendarSource.shouldSeedDefaultSource(
                hasSeededFlag: UserDefaults.standard.bool(forKey: seedKey),
                existingURLs: allSources.map(\.icsURL)
            ) {
                modelContext.insert(CustomCalendarSource(
                    name: CustomCalendarSource.defaultSourceName,
                    icsURL: CustomCalendarSource.defaultSourceURL,
                    isEnabled: false,
                    isImportant: false
                ))
                seedChanges = true
            }

            if seedChanges {
                // 落库成功才写 seed 标记：save 失败时标记仍写入会导致默认源永久不再插入
                try modelContext.save()
                UserDefaults.standard.set(true, forKey: seedKey)
            }
        } catch {
            // 查询/清理/落库任一失败均中止，下次启动重试（保留原失败重试语义）
            AppLogger.settings.error("订阅源 seed/去重失败（下次启动重试）: \(error.localizedDescription)")
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
