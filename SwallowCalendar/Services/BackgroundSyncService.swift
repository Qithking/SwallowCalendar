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
    /// 同步互斥标志；internal 供测试模拟同步进行中
    var isSyncing = false

    private let syncIntervalSeconds: TimeInterval = 60 * 60

    /// 外部变更（EKEventStore.changed）同步防抖任务与重试计数（reminder-sync-completeness）
    private var externalChangeTask: Task<Void, Never>?
    private var externalSyncRetryCount = 0

    /// 外部变更防抖间隔（与应用内改动防抖同为 2s）；internal 供测试注入短间隔
    var externalChangeDebounceSeconds: TimeInterval = 2

    /// 防抖到期后执行的同步动作；internal 供测试注入 spy 计数
    /// 外部变更同步跳过 ICS 订阅源（订阅有自身刷新节奏，AC-3）
    var externalSyncAction: () async -> Void = {
        await BackgroundSyncService.shared.syncOnce(includeSubscriptions: false)
    }

    private init() {}

    func configure(with container: ModelContainer) {
        self.modelContainer = container
    }

    func start() async {
        await syncOnce()
        startTimer()
    }

    /// 外部变更（EKEventStore.changed）触发入口：防抖合并连发通知后同步
    /// 日历事件与提醒（reminder-sync-completeness）
    func syncOnExternalChange() {
        // 每次新外部变更重置重试计数，重试机会针对单次变更而非进程全局
        externalSyncRetryCount = 0
        scheduleExternalSync()
    }

    /// 防抖调度：新通知取消上一个任务，静默 debounceSeconds 后只执行一次同步；
    /// 到期时若同步正在进行（isSyncing，如手动同步）则重排一次防抖重试，
    /// 避免该次外部变更被 syncOnce 的互斥 guard 静默丢弃（AC-4）
    private func scheduleExternalSync() {
        externalChangeTask?.cancel()
        externalChangeTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.externalChangeDebounceSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            if self.isSyncing && self.externalSyncRetryCount == 0 {
                self.externalSyncRetryCount += 1
                self.scheduleExternalSync()
                return
            }
            await self.externalSyncAction()
        }
    }

    /// 执行一次全量同步
    /// - Parameter includeSubscriptions: 是否同步 ICS 订阅源；外部变更防抖路径传 false
    ///   （订阅有自身刷新节奏，避免 EK 变更频繁触发网络刷新，AC-3），其余调用默认 true
    /// - Returns: nil 同步成功；非 nil 为失败原因描述（多个失败以"；"拼接），
    ///            供手动同步 UI 错误反馈；启动/定时/防抖等后台调用忽略返回值
    @discardableResult
    func syncOnce(includeSubscriptions: Bool = true) async -> String? {
        guard !isSyncing else { return "同步正在进行中，请稍后重试" }
        guard modelContainer != nil else { return "本地存储未就绪，请稍后重试" }

        isSyncing = true
        defer { isSyncing = false }

        // 使用 EventCacheService 的统一上下文（优先为环境上下文，与 @Query 共享）
        guard let context = EventCacheService.shared.context else { return "本地存储未就绪，请稍后重试" }

        var failures: [String] = []

        let preferences = fetchPreferences(context: context)

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

        // ICS 订阅源同步：外部变更防抖路径跳过（includeSubscriptions=false，AC-3）
        if includeSubscriptions {
            let customSources = fetchCustomSources(context: context)
            let enabledSources = customSources.filter { $0.isEnabled }
            // 始终调用同步（即使没有启用的源），确保禁用所有订阅时能清理旧缓存
            if !(await CalendarService.shared.cacheService.syncSubscriptionEvents(sources: enabledSources)) {
                failures.append("订阅日历同步失败")
            }
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
