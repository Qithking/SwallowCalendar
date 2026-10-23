//
//  BackgroundSyncService.swift
//  SwallowCalendar
//
//  后台静默定时同步服务
//

import Foundation
import SwiftData
import EventKit

@MainActor
final class BackgroundSyncService {
    static let shared = BackgroundSyncService()

    private var modelContainer: ModelContainer?
    private var syncTimer: Timer?
    private var isSyncing = false

    private let syncIntervalSeconds: TimeInterval = 60 * 60

    private init() {}

    func configure(with container: ModelContainer) {
        self.modelContainer = container
    }

    func start() async {
        await syncOnce()
        startTimer()
    }

    /// 执行一次全量同步
    /// - Returns: nil 同步成功；非 nil 为失败原因描述（多个失败以"；"拼接），
    ///            供手动同步 UI 错误反馈；启动/定时/防抖等后台调用忽略返回值
    @discardableResult
    func syncOnce() async -> String? {
        guard !isSyncing else { return "同步正在进行中，请稍后重试" }
        guard modelContainer != nil else { return "本地存储未就绪，请稍后重试" }

        isSyncing = true
        defer { isSyncing = false }

        // 使用 EventCacheService 的统一上下文（优先为环境上下文，与 @Query 共享）
        guard let context = EventCacheService.shared.context else { return "本地存储未就绪，请稍后重试" }

        var failures: [String] = []

        let preferences = fetchPreferences(context: context)
        let customSources = fetchCustomSources(context: context)

        // E-5：日历授权门槛只包住系统日历/提醒同步——ICS 订阅源同步不依赖 EventKit 授权，
        // 原顶部 guard 会使用户拒绝日历授权时订阅功能静默失效
        let hasCalendarAccess = CalendarService.shared.authorizationStatus == .fullAccess
        if hasCalendarAccess {
            let enabledCals = CalendarService.shared.enabledCalendars(preferences: preferences)

            if !enabledCals.isEmpty {
                if !(await CalendarService.shared.cacheService.syncEvents(from: CalendarService.shared, calendars: enabledCals)) {
                    failures.append("日历事件同步失败")
                } else {
                    // 初始同步成功后默认勾选全部系统日历（幂等：已有偏好记录则跳过），
                    // 使设置页勾选状态与同步/显示口径一致
                    CalendarService.shared.seedDefaultCalendarPreferences(
                        context: context,
                        preferences: preferences,
                        calendars: CalendarService.shared.calendars
                    )
                }
            } else {
                // clearSystemCalendarCache 为 @MainActor 同步方法，同类 @MainActor 上下文可直接调用
                CalendarService.shared.cacheService.clearSystemCalendarCache()
            }
        }

        if AppSettings.shared.syncSystemReminders && CalendarService.shared.reminderAuthorizationStatus == .fullAccess {
            if !(await CalendarService.shared.cacheService.syncReminders(from: CalendarService.shared)) {
                failures.append("提醒事项同步失败")
            }
        } else {
            // clearRemindersCache 为 @MainActor 同步方法，同类 @MainActor 上下文可直接调用
            CalendarService.shared.cacheService.clearRemindersCache()
        }

        let enabledSources = customSources.filter { $0.isEnabled }
        // 始终调用同步（即使没有启用的源），确保禁用所有订阅时能清理旧缓存
        if !(await CalendarService.shared.cacheService.syncSubscriptionEvents(sources: enabledSources)) {
            failures.append("订阅日历同步失败")
        }

        return failures.isEmpty ? nil : failures.joined(separator: "；")
    }

    private func startTimer() {
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: syncIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.syncOnce()
            }
        }
    }

    func stop() {
        syncTimer?.invalidate()
        syncTimer = nil
    }
    
    private func fetchPreferences(context: ModelContext) -> [CalendarPreference] {
        let descriptor = FetchDescriptor<CalendarPreference>()
        return (try? context.fetch(descriptor)) ?? []
    }

    private func fetchCustomSources(context: ModelContext) -> [CustomCalendarSource] {
        let descriptor = FetchDescriptor<CustomCalendarSource>()
        return (try? context.fetch(descriptor)) ?? []
    }
}
