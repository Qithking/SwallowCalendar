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

    /// 同步互斥时防抖重排的最大次数；internal 供测试收窄预算
    var maxExternalSyncRetries = 10

    /// 重试预算耗尽仍互斥时的待补跑标记；internal 供测试断言
    var pendingExternalResync = false

    /// 防抖到期后执行的同步动作；internal 供测试注入 spy 计数
    /// 外部变更同步跳过 ICS 订阅源（订阅有自身刷新节奏，AC-3）
    var externalSyncAction: () async -> Void = {
        await BackgroundSyncService.shared.syncOnce(includeSubscriptions: false)
    }

    /// 启动/重开面板同步动作；internal 供测试注入 spy。
    /// 参数 includeSubscriptions：首次启动 true（全量含 ICS），重开 false（AC-3 同语义跳过 ICS）
    var startupSyncAction: (_ includeSubscriptions: Bool) async -> Void = { includeSubscriptions in
        await BackgroundSyncService.shared.syncOnce(includeSubscriptions: includeSubscriptions)
    }

    /// 进程内是否已完成首次启动同步；重开面板走跳过 ICS 的轻量同步（panel-reopen-ics-refresh）
    /// internal 供测试复位
    var hasStartedOnce = false

    /// M8：农历镜像轻量补窗动作；internal 供测试注入 spy
    var lunarMirrorTopUpAction: () async -> Void = {
        await CalendarService.shared.reconcileAllLunarMirrors()
    }

    /// 上次补窗时刻（进程内）；启动必跑一次，进程存续期间每日补一次
    /// internal 供测试复位
    var lastLunarMirrorTopUpAt: Date?

    /// 补窗间隔；internal 供测试收窄
    var lunarMirrorTopUpInterval: TimeInterval = 24 * 60 * 60

    private init() {}

    func configure(with container: ModelContainer) {
        self.modelContainer = container
    }

    func start() async {
        // bug: panel-reopen-ics-refresh——主面板每次重建都调 start()，重开非数据变更事件，
        // 全量 ICS 网络刷新属 AC-3 语义外开销；首次启动保持全量，重开仅同步 EK 数据
        if hasStartedOnce {
            await startupSyncAction(false)
        } else {
            hasStartedOnce = true
            await startupSyncAction(true)
        }
        // M8：启动后补窗一次（不足窗口的镜像在此补齐；进程存续期间每日再补一次）
        await runLunarMirrorTopUpIfNeeded()
        startTimer()
    }

    /// 启动/每日一次轻量补窗：未到间隔直接返回，不产生额外 EK 读写
    func runLunarMirrorTopUpIfNeeded(now: Date = Date()) async {
        if let last = lastLunarMirrorTopUpAt, now.timeIntervalSince(last) < lunarMirrorTopUpInterval {
            return
        }
        lastLunarMirrorTopUpAt = now
        await lunarMirrorTopUpAction()
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
            if self.isSyncing {
                if self.externalSyncRetryCount < self.maxExternalSyncRetries {
                    // 同步进行中：重排一次防抖重试，避免被 syncOnce 互斥静默丢弃（AC-4）
                    self.externalSyncRetryCount += 1
                    self.scheduleExternalSync()
                } else {
                    // BUG-10：原实现只重试一次，第二次撞互斥即静默丢弃（最长 60 分钟才可见）；
                    // 预算耗尽后置待补跑标记，由本轮 syncOnce 结束时立即消费
                    self.pendingExternalResync = true
                }
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
        defer {
            isSyncing = false
            // BUG-10：长同步期间外部变更若重试用尽，同步结束立即补跑一次（跳过 ICS，与外部变更同口径）
            if pendingExternalResync {
                pendingExternalResync = false
                Task { [weak self] in
                    await self?.externalSyncAction()
                }
            }
        }

        // 使用 EventCacheService 的统一上下文（优先为环境上下文，与 @Query 共享）
        guard let context = EventCacheService.shared.context else { return "本地存储未就绪，请稍后重试" }

        var failures: [String] = []

        // E-5：日历授权门槛只包住系统日历/提醒同步——ICS 订阅源同步不依赖 EventKit 授权，
        // 原顶部 guard 会使用户拒绝日历授权时订阅功能静默失效
        let hasCalendarAccess = CalendarService.shared.authorizationStatus == .fullAccess
        // R-6：nil = 本地偏好查询失败，跳过系统日历同步段——失败伪装真空会触发
        // enabledCalendars 全量分支 + seedDefaultCalendarPreferences 放行，
        // 把用户已裁剪的勾选配置持久化重置；提醒同步不依赖偏好，照常执行
        if let preferences = fetchPreferences(context: context) {
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
        } else if hasCalendarAccess {
            failures.append("本地偏好读取失败，本轮跳过系统日历同步以保护用户配置")
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
            // R-6：nil = 订阅源查询失败，跳过本轮订阅同步——失败伪装空列表会令
            // syncSubscriptionEvents(sources: []) 清空订阅缓存
            if let customSources = fetchCustomSources(context: context) {
                let enabledSources = customSources.filter { $0.isEnabled }
                // 始终调用同步（即使没有启用的源），确保禁用所有订阅时能清理旧缓存
                if !(await CalendarService.shared.cacheService.syncSubscriptionEvents(sources: enabledSources)) {
                    failures.append("订阅日历同步失败")
                }
            } else {
                failures.append("订阅源读取失败，本轮跳过订阅同步以保护订阅缓存")
            }
        }

        return failures.isEmpty ? nil : failures.joined(separator: "；")
    }

    private func startTimer() {
        syncTimer?.invalidate()
        // R-15：加入 .common mode——scheduledTimer 默认挂 default mode，
        // UI 交互（滚动/拖拽 tracking mode）期间周期同步暂停（A-16 同型遗漏）
        let timer = Timer(timeInterval: syncIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.syncOnce()
                // M8：定时器顺带检查每日补窗（间隔未到时不产生 EK 读写）
                await self?.runLunarMirrorTopUpIfNeeded()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        syncTimer = timer
    }

    func stop() {
        syncTimer?.invalidate()
        syncTimer = nil
    }
    
    /// R-6：返回 nil = 查询失败（数据库异常），空数组才是新用户真空；
    /// 失败伪装真空会走 enabledCalendars 全量分支 + seedDefaultCalendarPreferences
    /// 放行落库全勾，把用户已裁剪的日历勾选配置持久化重置
    private func fetchPreferences(context: ModelContext) -> [CalendarPreference]? {
        let descriptor = FetchDescriptor<CalendarPreference>()
        return CacheFetch.optional(descriptor, in: context, operation: "日历偏好查询")
    }

    /// R-6：返回 nil = 查询失败；失败伪装空列表会令 syncSubscriptionEvents(sources: [])
    /// 清空订阅缓存
    private func fetchCustomSources(context: ModelContext) -> [CustomCalendarSource]? {
        let descriptor = FetchDescriptor<CustomCalendarSource>()
        return CacheFetch.optional(descriptor, in: context, operation: "订阅源查询")
    }
}
