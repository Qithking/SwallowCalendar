//
//  ReminderAlertService.swift
//  SwallowCalendar
//
//  待办事项到期提醒服务
//

import Foundation
@preconcurrency import AppKit
import SwiftData
import os
import SwiftUI  // 为了导入 CalendarEvent

/// 去重键：持久化元素 "eventID|alertTs"（plan 步骤 5 / AC-7 多级提醒各级独立去重）。
/// BUG-03：旧格式（无 "|"）键不再惰性兼容——原实现回退 .distantPast 并以通配语义
/// 匹配任意 alertTime，叠加 baseID 归一化后整条序列永久静默；现改为解析失败即丢弃
struct ReminderAlertKey: Equatable {
    let eventID: String
    let alertTime: Date

    init(eventID: String, alertTime: Date) {
        self.eventID = eventID
        self.alertTime = alertTime
    }

    /// 解码持久化串：时间戳取末段 "|" 之后（baseID 恒不含 "|"，末段分割对
    /// 各格式均正确——复合 eventID "baseID|occ:<epoch>"（R-1 起候选行）、
    /// 再加时间戳的完整键）；无 "|"、末段非有限数字 → nil（旧格式键一次性迁移丢弃）
    init?(raw: String) {
        guard let idx = raw.lastIndex(of: "|"),
              let ts = TimeInterval(raw[raw.index(after: idx)...]),
              ts.isFinite else { return nil }
        self.eventID = String(raw[..<idx])
        self.alertTime = Date(timeIntervalSince1970: ts)
    }

    /// 编码为持久化串（秒级时间戳）
    var encoded: String {
        "\(eventID)|\(String(format: "%.0f", alertTime.timeIntervalSince1970))"
    }
}

/// C2 稍后提醒记录：持久化到 UserDefaults（键 snoozeRecordsKey），
/// 由 60s 轮询检查触发，不建独立 Timer
struct SnoozeRecord: Codable, Equatable {
    let eventID: String
    let fireDate: Date
}

@MainActor
final class ReminderAlertService {
    static let shared = ReminderAlertService()
    
    private var timer: Timer?
    /// 准点调度定时器（bug: due-alert-punctual-scheduling）：单次触发于最近的
    /// 未提醒 alertTime（含 snooze fireDate），消除 60s 轮询最坏延迟 60 秒的弹窗不及时；
    /// 60s 轮询保留作兜底，两者经 (eventID, alertTime) 去重不会重复弹窗
    private var dynamicTimer: Timer?
    private var lastAlertedEventIDs: [String] = []
    /// 持久化已提醒事件ID的 UserDefaults 键
    private static let alertedEventIDsKey = "ReminderAlertService.lastAlertedEventIDs"
    /// 已提醒事件ID的最大缓存数量
    private let maxAlertedEventIDs = 1000
    /// 持久化上次检查时间的 UserDefaults 键（B-14）
    private static let lastCheckTimeKey = "ReminderAlertService.lastCheckTime"
    /// 上次检查时间（B-14：挂起/睡眠恢复后以"上次检查~now"为提醒窗口，避免漏提醒）
    private var lastCheckTime: Date?
    /// 启动式过期检查已完成标志（bug: main-panel-reopen-expired-popup）：
    /// 主面板每次重开都会重跑 ContentView.task → checkExpiredEvents()，
    /// 该标志保证启动式过期检查在应用生命周期内仅首次真正执行
    private var hasCompletedStartupExpiredCheck = false
    /// 启动检查执行中标志（A-20：完成标志后置位后，防执行期间重入双弹）
    private var isStartupCheckInFlight = false
    /// block observer token 必须持有，否则注册即释放失效（A-17）
    private var changeObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    private init() {
        // 从 UserDefaults 恢复已提醒事件ID，避免应用重启后重复弹窗
        // BUG-03：一次性迁移——无法解析的旧格式键（无时间戳）直接丢弃，避免永久静默
        if let saved = UserDefaults.standard.stringArray(forKey: Self.alertedEventIDsKey) {
            let sanitized = Self.sanitizedAlertedEventIDs(saved)
            self.lastAlertedEventIDs = sanitized
            if sanitized.count != saved.count {
                AppLogger.reminder.info("清理无法解析的旧提醒去重键 count=\(saved.count - sanitized.count)")
                UserDefaults.standard.set(sanitized, forKey: Self.alertedEventIDsKey)
            }
        }
        // B-14：恢复上次检查时间，重启后窗口下界不回退到"无记录"状态
        let savedTime = UserDefaults.standard.double(forKey: Self.lastCheckTimeKey)
        if savedTime > 0 {
            self.lastCheckTime = Date(timeIntervalSince1970: savedTime)
        }
        // 准点调度联动（bug: due-alert-punctual-scheduling）：
        // 缓存变更（同步/新建/编辑/完成广播）后重算下次触发时刻
        changeObserver = NotificationCenter.default.addObserver(
            forName: .cachedEventsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rescheduleDynamicTimer() }
        }
        // 睡眠唤醒：补一次检查（B-14 窗口覆盖挂起区间，挂起期漏掉的提醒即时弹出）
        // 并重算准点调度（系统挂起期间 Timer 不触发）
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.checkDueEvents()
                self?.rescheduleDynamicTimer()
            }
        }
    }
    
    /// 配置服务
    func configure(with container: ModelContainer) {
        // modelContainer 已不再需要，保留方法以兼容调用方
    }

    /// 测试专用：复位启动检查标志、已提醒缓存与检查窗口下界（@testable 可见，产线不调用）
    func resetForTesting() {
        hasCompletedStartupExpiredCheck = false
        lastAlertedEventIDs = []
        // 测试隔离：连同内存中的 lastCheckTime 一并复位，
        // 否则前一个用例遗留值会抬高下一个用例的窗口下界导致漏判
        lastCheckTime = nil
    }
    
    /// 启动提醒检查
    func startMonitoring() {
        stopMonitoring()
        
        // 确保在主线程上执行检查
        DispatchQueue.main.async { [weak self] in
            // 不要立即检查过期事项，等待数据同步完成后由外部调用 checkExpiredEvents()
            // 每分钟检查一次是否有待办事项到期
            let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
                Task {
                    await self?.checkDueEvents()
                }
            }
            // A-16：加入 .common mode——scheduledTimer 默认挂 default mode，
            // UI 交互（滚动/拖拽 tracking mode）期间 60s 轮询暂停导致提醒延迟
            RunLoop.main.add(timer, forMode: .common)
            self?.timer = timer
            // 准点调度（上下文未就绪时为无害空转，数据同步后经检查/广播重新调度）
            self?.rescheduleDynamicTimer()
        }
    }
    
    /// 检查到期的事件（供数据同步完成后调用）
    /// 启动时的检查会忽略 lastAlertedEventIDs 过滤，确保过期事项始终提示
    /// bug: main-panel-reopen-expired-popup：主面板重开会重建 ContentView 并重跑
    /// .task → initializeServices → 本方法，原实现每次都以启动式语义弹窗。
    /// 按需求「仅应用初始启动时弹」：应用生命周期内仅首次调用真正执行，
    /// 后续（主面板重开触发）直接跳过
    func checkExpiredEvents() async {
        guard !hasCompletedStartupExpiredCheck, !isStartupCheckInFlight else {
            AppLogger.reminder.info("启动过期检查已完成或执行中，跳过本次（主面板重开触发）")
            return
        }
        // A-20：inFlight 防执行期重入；完成标志在检查完成后置位——
        // 原前置位使检查中途失败/被中断后永不重试
        isStartupCheckInFlight = true
        // R-14：仅检查成功才置位完成标志——context 未就绪/fetch 失败时返回 false，
        // 标志保持未置位，本进程内后续调用（主面板重开/数据同步完成）可重试
        let succeeded = await checkDueEvents(includeExpired: true, ignoreAlertedCache: true)
        isStartupCheckInFlight = false
        if succeeded {
            hasCompletedStartupExpiredCheck = true
            AppLogger.reminder.info("数据同步后过期事项检查完成")
        } else {
            AppLogger.reminder.error("启动过期检查失败，完成标志未置位，等待下次触发重试")
        }
    }
    
    /// 测试辅助：跑一次常规定时检查（bug: due-reminder-zero-offset-miss，@testable 可见）
    func runDueCheckForTesting() async {
        await checkDueEvents()
    }

    /// 停止提醒检查
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        dynamicTimer?.invalidate()
        dynamicTimer = nil
    }

    // MARK: - 准点调度（bug: due-alert-punctual-scheduling）

    /// 调度取数窗口：startDate 落入本区间的未完成事项才可能产生近期 alertTime。
    /// alertTime = startDate - offset*60，offset ∈ [-cap, cap]：
    /// - 提前档要求 startDate ≤ now + cap
    /// - 延后档要求 startDate ≥ now - cap（开始已过、提醒仍在未来）
    /// cap 取 365 天，覆盖 1 个月/6 个月预设与自定义上限
    static func scheduleWindow(now: Date) -> (lower: Date, upper: Date) {
        let span = TimeInterval(CachedEvent.maxReminderLeadMinutes * 60)
        return (now.addingTimeInterval(-span), now.addingTimeInterval(span))
    }

    /// 计算下一次应触发提醒的时刻（纯函数，语义由 ReminderAlertDynamicScheduleTests 锁定）
    /// 候选：各事件各级 alertTime（offsets 原样 + 隐式到点档）+ snooze fireDate，
    /// 均取严格晚于 now 的最早值；智能跳过与无开始时间事件剔除，已完成事件由调用方粗筛剔除。
    /// 无候选返回 nil（调用方不调度，60s 轮询兜底）
    static func nextTriggerTime(now: Date, events: [CachedEvent], snoozeRecords: [SnoozeRecord], context: ModelContext) -> Date? {
        var candidates: [Date] = []
        for event in events {
            guard !HolidaySkipResolver.isSkipped(of: event, context: context) else { continue }
            guard let startDate = event.startDate else { continue }
            var offsets = event.reminderOffsets
            // 隐式到点档：无提前提醒也必须在到期时刻提醒（用户澄清「无」只指不设提前提醒）
            if !offsets.contains(0) { offsets.append(0) }
            for offset in offsets {
                let t = startDate.addingTimeInterval(TimeInterval(-offset * 60))
                if t > now { candidates.append(t) }
            }
        }
        candidates.append(contentsOf: snoozeRecords.map(\.fireDate).filter { $0 > now })
        return candidates.min()
    }

    /// 重算并调度准点触发定时器：检查完成 / .cachedEventsChanged / snooze / 睡眠唤醒后调用。
    /// 单次 Timer 精确触发于下次 alertTime，触发后跑一次常规检查（窗口判定+去重弹窗）再重调度；
    /// 取不到候选时不调度，由 60s 轮询兜底并在其后再次尝试调度
    private func rescheduleDynamicTimer() {
        dynamicTimer?.invalidate()
        dynamicTimer = nil
        guard let context = EventCacheService.shared.context else { return }
        let now = Date()
        // 粗筛口径与常规检查一致：窗口按最大提前/延后量扩展，覆盖 1 个月/6 个月等长提前档
        let userCategory = EventCategory.user.rawValue
        let window = Self.scheduleWindow(now: now)
        let lower = window.lower
        let upper = window.upper
        let distantPast = Date.distantPast
        let distantFuture = Date.distantFuture
        let descriptor = FetchDescriptor<CachedEvent>(
            predicate: #Predicate {
                $0.categoryRaw == userCategory &&
                !$0.isCompleted &&
                $0.startDate != nil &&
                ($0.startDate ?? distantPast) >= lower &&
                ($0.startDate ?? distantFuture) <= upper
            },
            sortBy: [SortDescriptor(\.startDate)]
        )
        // bug: reminder-fetch-swallow——try? 吞错无日志，fetch 失败时动态提醒调度
        // 链路静默失效（不重排定时器）且无迹可查；记录错误后同样终止本次调度
        let events: [CachedEvent]
        do {
            events = try context.fetch(descriptor)
        } catch {
            AppLogger.reminder.error("提醒调度窗口查询失败: \(String(describing: error))")
            return
        }
        guard let next = Self.nextTriggerTime(now: now, events: events, snoozeRecords: Self.loadSnoozeRecords(), context: context) else { return }
        let interval = max(0, next.timeIntervalSince(now))
        // R-16：加入 .common mode——scheduledTimer 默认挂 default mode，
        // UI 交互期间准点提醒暂停延迟弹出（A-16/R-15 同型遗漏）
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.checkDueEvents()
                self?.rescheduleDynamicTimer()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dynamicTimer = timer
        // 用户可感知的准点提醒：容差收紧到 1 秒
        dynamicTimer?.tolerance = 1
    }
    
    /// 检查到期的待办事项
    /// - Parameters:
    ///   - includeExpired: 是否包含已过期的事项（仅在应用启动时使用）
    ///   - ignoreAlertedCache: 是否忽略已提醒缓存（启动时为 true，确保过期事项始终提示）
    /// - Returns: 检查是否成功完成（R-14：context 未就绪或 fetch 失败返回 false，
    ///            供启动过期检查判断是否置位完成标志；常规调用方忽略返回值）
    @discardableResult
    private func checkDueEvents(includeExpired: Bool = false, ignoreAlertedCache: Bool = false) async -> Bool {
        // 使用 EventCacheService 的上下文，确保与待办列表显示的数据一致
        guard let context = EventCacheService.shared.context else {
            AppLogger.reminder.warning("EventCacheService 未配置")
            return false
        }
        let now = Date()
        let calendar = Calendar.current

        // 先获取所有未完成的用户事件，然后在内存中过滤日期
        // 这种方式可以避免 SwiftData Predicate 的复杂语法问题
        // EventCategory.user.rawValue 的值是 "用户"（中文字符串）
        let userCategory = "用户"

        // B-27：把提醒时间窗口换算为 startDate 窗口下沉到谓词粗筛，避免每分钟全表拉取。
        // alertTime = startDate - offset*60，offset ∈ [-cap, cap]（正=提前、负=延后），
        // 因此 alertTime 命中窗口的必要条件是 startDate ∈ [cap 下界放宽, now + cap]，
        // 精确判定仍由下方内存过滤完成。cap = 365 天，覆盖 1 个月/6 个月长提前档。
        // 常规检查下界为 B-14 的 lastCheckTime 窗口（无记录回退 90 秒），并放宽到
        // now - cap 以覆盖「开始已过、延后档提醒仍在未来」；includeExpired 下界放开
        let maxReminderLeadSeconds = TimeInterval(CachedEvent.maxReminderLeadMinutes * 60)
        let fetchUpperBound = now.addingTimeInterval(maxReminderLeadSeconds)
        let windowStart = lastCheckTime ?? calendar.date(byAdding: .second, value: -90, to: now)!
        let fetchLowerBound = includeExpired
            ? Date.distantPast
            : min(windowStart, now.addingTimeInterval(-maxReminderLeadSeconds))
        // 哨兵日期用局部常量捕获：#Predicate 宏内直接写 Date.distantPast 会展开成
        // 静态成员 keypath（Value<Date.Type>），既不符合 StandardPredicateExpression，
        // 还会使复杂合取表达式的类型推断超时；局部常量捕获后转为 Value 表达式
        let distantPast = Date.distantPast
        let distantFuture = Date.distantFuture
        let baseDescriptor = FetchDescriptor<CachedEvent>(
            predicate: #Predicate {
                $0.categoryRaw == userCategory &&
                !$0.isCompleted &&
                $0.startDate != nil &&
                ($0.startDate ?? distantPast) >= fetchLowerBound &&
                ($0.startDate ?? distantFuture) <= fetchUpperBound
            },
            sortBy: [SortDescriptor(\.startDate)]
        )

        do {
            var allUserEvents = try context.fetch(baseDescriptor)
            // bug: startup-expired-popup-recurring-miss：循环 base 行 startDate 只是「下一期」
            // 游标，被越过的未完成历史实例直查漏报（主面板经锚点展开可见）——启动过期
            // 检查把 base 行替换为同源展开实例，与主面板判定源对齐（R-1 起常规窗口
            // 路径同样替换，见下方 recurringWindowCandidates）
            if includeExpired {
                allUserEvents = Self.expiredCheckCandidates(
                    rawEvents: allUserEvents,
                    upperBound: fetchUpperBound,
                    context: context
                )
            } else {
                // R-1：常规窗口内循环 base 行同样替换为窗口内展开实例（复合 ID），
                // 弹窗完成走 occurrence 级路径（写历史/推进游标/EK 不污染），
                // 与启动路径语义对齐，消除双语义并存。
                // bug: poll-window-completed-base-recurring-miss：粗筛 !$0.isCompleted
                // 会把 base 行被置位的循环任务滤掉（旧版本完成操作整条置位且不写
                // 完成历史——R-1 修复前行为，存量已污染），主面板 expandOccurrences
                // 不看该位 → 列表显示但提醒静默；本方法补捞全部循环 base 后统一展开
                allUserEvents = Self.pollWindowCandidates(
                    rawEvents: allUserEvents,
                    windowStart: windowStart,
                    upperBound: fetchUpperBound,
                    context: context
                )
            }

            // 步骤 8 多级扫描：按 offsets 各级生成 alertTime，逐级窗口判定，
            // 产出 (事件, 本次应触发的各级 alertTime) 对；同一事件多级同时到期合并为一条
            var duePairs: [(event: CachedEvent, alertTimes: [Date])] = []
            for event in allUserEvents {
                // 智能跳过节假日（语义 v3）：勾选任务 startDate 落休日/周末当天静默跳过，不提醒
                guard !HolidaySkipResolver.isSkipped(of: event, context: context) else { continue }
                guard let startDate = event.startDate else { continue }
                let offsets = event.reminderOffsets
                var alertTimes: [Date] = []
                if includeExpired {
                    // 启动时的过期检查：
                    // - 未设置提醒（单级 0）：事件已过期（startDate < now）
                    // - 设置了提醒：任一级 alertTime 已过即触发
                    if event.reminderOffsetsJSON == nil && event.reminderMinutes == 0 {
                        if startDate < now { alertTimes = [startDate] }
                    } else {
                        alertTimes = offsets.compactMap { offset in
                            let t = startDate.addingTimeInterval(TimeInterval(-offset * 60))
                            return t <= now ? t : nil
                        }
                    }
                } else {
                    // 常规定时检查：逐级窗口判定 [windowStart, now]；
                    // 0 档（准点提醒/未设置提醒 fallback）视为准点档 alertTime=startDate
                    // （bug: due-reminder-zero-offset-miss：与启动检查「未设置提醒过期弹 startDate」对齐，
                    // 已弹过的键经 hasAlertedKey 去重不重复弹）
                    // bug: due-reminder-onset-miss：设置了提前提醒（offsets 不含 0 档）的事件
                    // 仅在提前档时刻弹，事件开始时刻无档位命中导致到点不提醒；
                    // 并入隐式准点档与 fallback [0] 语义对齐（到点必提醒），各档键独立去重
                    // B-14：窗口下界用持久化的上次检查时间——应用挂起/睡眠超 90 秒后，
                    // 固定 90 秒窗口会滤掉挂起期间到期的事项导致漏提醒；
                    // 无记录时回退 90 秒窗口（配合 60 秒定时器确保不遗漏）
                    var candidates = offsets
                    if !candidates.contains(0) { candidates.append(0) }
                    alertTimes = candidates.compactMap { offset in
                        let t = startDate.addingTimeInterval(TimeInterval(-offset * 60))
                        return (t <= now && t >= windowStart) ? t : nil
                    }
                }
                guard !alertTimes.isEmpty else { continue }
                // (eventID, alertTime) 级别级去重：已提醒过的级剔除（启动时忽略缓存确保过期事项始终提示）；
                // 旧格式键（纯 eventID）经 hasAlertedKey 惰性兼容
                if !ignoreAlertedCache {
                    alertTimes = alertTimes.filter { !hasAlertedKey(eventID: event.eventID, alertTime: $0) }
                }
                if !alertTimes.isEmpty {
                    duePairs.append((event, alertTimes))
                }
            }

            // C2：snooze 到期事件并入本次弹窗（同事件以常规触发优先，按 eventID 去重）
            var mergedEvents = duePairs.map(\.event)
            for snoozed in consumeDueSnoozes(now: now)
            where !mergedEvents.contains(where: { $0.eventID == snoozed.eventID }) {
                mergedEvents.append(snoozed)
            }

            if !mergedEvents.isEmpty {
                // 日志记录触发级别与时刻（不带标题，避免隐私泄露）
                for pair in duePairs {
                    for alertTime in pair.alertTimes {
                        // startDate 异常缺失时以 alertTime 兜底（level 归 0），避免强解包崩溃
                        let level = Int((pair.event.startDate ?? alertTime).timeIntervalSince(alertTime) / 60)
                        AppLogger.reminder.info("到期提醒弹出 id=\(pair.event.eventID) level=\(level)min alertTime=\(Int(alertTime.timeIntervalSince1970)) isReminder=\(pair.event.isReminder)")
                    }
                }
                // 合并显示所有到期/即将到期的事项
                let isExpired = includeExpired || mergedEvents.allSatisfy { ($0.startDate ?? now) < now }
                showCombinedAlert(for: mergedEvents, isExpired: isExpired)
                // 记录已提醒的各级键（追加到末尾，保持插入顺序；snooze 键已在 consumeDueSnoozes 记录）
                duePairs.forEach { pair in
                    pair.alertTimes.forEach { alertTime in
                        lastAlertedEventIDs.append(ReminderAlertKey(eventID: pair.event.eventID, alertTime: alertTime).encoded)
                    }
                }
                // 持久化到 UserDefaults，避免应用重启后重复弹窗
                persistAlertedEventIDs()
                // 限制数组大小，避免内存泄漏
                trimAlertedEventIDsIfNeeded()
                // 2026-11-06 口径：移除原 BUG-04 的 300s 自动重提醒（对已开始未完成事项
                // 入 SnoozeRecord 再重弹）。到点本身有准点提醒，过期项不再自动重复打扰；
                // 用户主动「稍后提醒」仍由 snooze() 入队，由 consumeDueSnoozes 触发。
            }
            // B-14：本次检查已覆盖到 now，记录检查时间作为下次检查（含挂起恢复后）的窗口下界；
            // 仅在 fetch 成功后更新，失败时保留旧值以免跳过失败区间的提醒
            lastCheckTime = now
            UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Self.lastCheckTimeKey)
            // 检查完成后重算准点调度（下次 alertTime 可能已变化）
            rescheduleDynamicTimer()
            return true
        } catch {
            AppLogger.reminder.error("检查到期事件失败: \(String(describing: error))")
            return false
        }
    }
    
    /// 弹窗显示期间外部变更同步（bug: four-view-todo-sync）：
    /// 重查快照每行的当前状态——已完成/已删除的行移除（等效单条 removeRow），
    /// 未完成行重建为最新字段（别处编辑后的标题/时间同步显示）。
    /// occurrence 复合 ID 经 displayOccurrence（已完成/失效返回 nil），
    /// 普通行直查主表
    static func refreshedDisplayRows(events: [CachedEvent], context: ModelContext) -> [CachedEvent] {
        events.compactMap { event -> CachedEvent? in
            if CachedEvent.parseOccurrenceID(event.eventID) != nil {
                return EventCacheService.shared.displayOccurrence(withID: event.eventID, context: context)
            }
            // #Predicate 宏内直接引用闭包参数会被捕获成 keypath 表达式，
            // 提取局部常量转为 Value 捕获（与 displayOccurrence 同款）
            let rowID = event.eventID
            let descriptor = FetchDescriptor<CachedEvent>(
                predicate: #Predicate { $0.eventID == rowID }
            )
            guard let fresh = try? context.fetch(descriptor).first, !fresh.isCompleted else { return nil }
            return fresh
        }
    }

    /// 启动过期检查候选集（bug: startup-expired-popup-recurring-miss）：
    /// 循环 base 行（用户分类、游标或锚点早于窗口右界）替换为
    /// expandOccurrences 同源展开实例（窗口 [distantPast, upperBound]），
    /// 普通行原样保留，已完成历史实例剔除不弹窗。
    /// 注意不得按 base.isCompleted 过滤循环行（bug 第二轮）：旧版本完成操作
    /// 会置位 base 行且不写完成历史，主面板 expandOccurrences 也不看该位——
    /// 按它过滤会与主面板判定源不一致，实例级 isCompleted 才是判定标准
    static func expiredCheckCandidates(rawEvents: [CachedEvent], upperBound: Date, context: ModelContext) -> [CachedEvent] {
        let userCategory = EventCategory.user.rawValue
        let noneRaw = RecurrenceType.none.rawValue
        let distantFuture = Date.distantFuture
        let descriptor = FetchDescriptor<CachedEvent>(
            predicate: #Predicate {
                $0.categoryRaw == userCategory &&
                $0.recurrenceTypeRaw != nil &&
                $0.recurrenceTypeRaw != noneRaw &&
                (($0.startDate ?? distantFuture) < upperBound ||
                 ($0.originStartDate ?? distantFuture) < upperBound)
            }
        )
        guard let recurringBases = try? context.fetch(descriptor), !recurringBases.isEmpty else {
            return rawEvents
        }
        let baseIDs = Set(recurringBases.map(\.eventID))
        var result = rawEvents.filter { !baseIDs.contains($0.eventID) }
        // bug: startup-expired-check-n-plus-one——.distantPast 窗口下展开从锚点逐周期推进，
        // skipHolidays 时逐 occurrence 触发 isRestDay 查库，启动开销随锚点年龄线性增长；
        // 展开前单次窄查询预热窗口内休/班判定，循环退化为内存命中（判定语义不变）
        if recurringBases.contains(where: \.skipHolidays) {
            let origins = recurringBases.compactMap { $0.originStartDate ?? $0.startDate }
            if let earliest = origins.min() {
                HolidaySkipResolver.warmRestFlags(from: earliest, to: upperBound, context: context)
            }
        }
        for base in recurringBases {
            let instances = EventCacheService.shared.expandOccurrences(
                of: base,
                windowStart: .distantPast,
                windowEnd: upperBound,
                context: context
            )
            result.append(contentsOf: instances.filter { !$0.isCompleted })
        }
        return result
    }

    /// 常规轮询窗口候选（bug: window-poll-recurring-base-id-completion，R-1）：
    /// 常规 60s 轮询路径捞到的循环 base 行同样替换为窗口内展开实例（复合 ID），
    /// 与启动路径（expiredCheckCandidates）完成语义对齐——否则弹窗行携带 base ID，
    /// markAsCompleted 经 parseOccurrenceID=nil 走整条完成主路径
    /// （EK 整条污染、无完成历史、游标不推进），双语义并存。
    /// 粗筛结果中的循环行 startDate 已落 [windowStart, upperBound]，展开同窗口
    /// 必产出该期实例；普通单次行原样保留
    static func recurringWindowCandidates(
        rawEvents: [CachedEvent],
        windowStart: Date,
        upperBound: Date,
        context: ModelContext
    ) -> [CachedEvent] {
        let noneRaw = RecurrenceType.none.rawValue
        let recurringBases = rawEvents.filter { ($0.recurrenceTypeRaw ?? noneRaw) != noneRaw }
        guard !recurringBases.isEmpty else { return rawEvents }
        let baseIDs = Set(recurringBases.map(\.eventID))
        var result = rawEvents.filter { !baseIDs.contains($0.eventID) }
        for base in recurringBases {
            let instances = EventCacheService.shared.expandOccurrences(
                of: base,
                windowStart: windowStart,
                windowEnd: upperBound,
                context: context
            )
            // 已完成历史实例不进候选（实例级 isCompleted 为判定标准，同启动路径）
            result.append(contentsOf: instances.filter { !$0.isCompleted })
        }
        return result
    }

    /// 常规轮询窗口候选（含补捞，bug: poll-window-completed-base-recurring-miss）：
    /// 粗筛谓词 !$0.isCompleted 会把 base 行被置位的循环任务滤掉（旧版本完成操作
    /// 整条置位且不写完成历史——R-1 修复前行为，存量数据已污染），而主面板
    /// expandOccurrences 不看该位 → 列表显示但提醒静默。与启动路径
    /// expiredCheckCandidates 同构：独立查询全部循环 base（不含 isCompleted 条件）
    /// 合并去重后统一展开，实例级 isCompleted 才是判定标准
    /// （recurringWindowCandidates 的实例过滤兜底，已完成历史实例不进候选）
    static func pollWindowCandidates(
        rawEvents: [CachedEvent],
        windowStart: Date,
        upperBound: Date,
        context: ModelContext
    ) -> [CachedEvent] {
        let userCategory = EventCategory.user.rawValue
        let noneRaw = RecurrenceType.none.rawValue
        let distantFuture = Date.distantFuture
        let descriptor = FetchDescriptor<CachedEvent>(
            predicate: #Predicate {
                $0.categoryRaw == userCategory &&
                $0.recurrenceTypeRaw != nil &&
                $0.recurrenceTypeRaw != noneRaw &&
                (($0.startDate ?? distantFuture) < upperBound ||
                 ($0.originStartDate ?? distantFuture) < upperBound)
            }
        )
        var merged = rawEvents
        do {
            let missed = try context.fetch(descriptor)
            let seen = Set(rawEvents.map(\.eventID))
            merged.append(contentsOf: missed.filter { !seen.contains($0.eventID) })
        } catch {
            AppLogger.reminder.error("常规轮询循环 base 补捞失败: \(String(describing: error))")
        }
        return recurringWindowCandidates(
            rawEvents: merged,
            windowStart: windowStart,
            upperBound: upperBound,
            context: context
        )
    }

    /// 显示合并的过期事项提醒弹窗（自定义 SwiftUI 窗口，替代系统 NSAlert）
    /// G4：单条完成接 markAsCompleted、稍后提醒接 snooze
    private func showCombinedAlert(for events: [CachedEvent], isExpired: Bool) {
        ReminderAlertWindowController.shared.show(
            events: events,
            isExpired: isExpired,
            onCompleteAll: { [weak self] in
                Task { @MainActor in
                    // B-15：仅标记已开始的实例——"提醒时间已到但事件尚未开始"（startDate > now）
                    // 的实例被提前标完成会错误推进周期任务序列
                    guard let self else { return }
                    for event in events where (event.startDate ?? Date()) <= Date() {
                        await self.markAsCompleted(eventID: event.eventID)
                    }
                }
            },
            onEventComplete: { [weak self] eventID in
                Task { @MainActor in
                    // 单条完成与"全部完成"同一 B-15 语义：仅已开始实例才标记
                    guard let self,
                          let event = events.first(where: { $0.eventID == eventID }),
                          (event.startDate ?? Date()) <= Date() else { return }
                    await self.markAsCompleted(eventID: eventID)
                }
            },
            onSnooze: { [weak self] eventID, minutes in
                Task { @MainActor in
                    self?.snooze(eventID: eventID, minutes: minutes)
                }
            }
        )
    }

    // MARK: - C2 稍后提醒（snooze）

    private static let snoozeRecordsKey = "ReminderAlertService.snoozeRecords"

    /// 稍后提醒：弹窗关闭，约 minutes 分钟后重新提醒（startDate 不变，AC-5）
    /// SnoozeRecord 入 UserDefaults，由 60s 轮询检查触发；同事件重复 snooze 覆盖旧记录
    func snooze(eventID: String, minutes: Int) {
        var records = Self.loadSnoozeRecords()
        records.removeAll { $0.eventID == eventID }
        records.append(SnoozeRecord(eventID: eventID, fireDate: Date().addingTimeInterval(TimeInterval(minutes * 60))))
        Self.saveSnoozeRecords(records)
        // snooze 时刻可能早于当前调度 → 重算准点触发
        rescheduleDynamicTimer()
        AppLogger.reminder.info("稍后提醒 id=\(eventID) minutes=\(minutes)")
    }

    static func loadSnoozeRecords() -> [SnoozeRecord] {
        guard let data = UserDefaults.standard.data(forKey: snoozeRecordsKey),
              let records = try? JSONDecoder().decode([SnoozeRecord].self, from: data) else { return [] }
        return records
    }

    static func saveSnoozeRecords(_ records: [SnoozeRecord]) {
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: snoozeRecordsKey)
        }
    }

    /// 收集到期的 snooze 记录（checkDueEvents 轮询内调用，复用轮询不建独立 Timer）
    /// 到期记录：事件存在且未完成 → 触发并转 AlertKey（后续去重生效）；
    /// 失效（已删除/已完成）→ GC 清除（防幽灵提醒）
    private func consumeDueSnoozes(now: Date) -> [CachedEvent] {
        guard let context = EventCacheService.shared.context else { return [] }
        let records = Self.loadSnoozeRecords()
        guard !records.isEmpty else { return [] }

        var triggered: [CachedEvent] = []
        var surviving: [SnoozeRecord] = []
        for record in records {
            if record.fireDate > now {
                surviving.append(record)
                continue
            }
            let descriptor = FetchDescriptor<CachedEvent>(
                predicate: #Predicate { $0.eventID == record.eventID }
            )
            // 复合 occurrence ID 实例未落库：回查本体重建展示实例（已完成实例被剔除）
            let resolved = try? context.fetch(descriptor).first
                ?? EventCacheService.shared.displayOccurrence(withID: record.eventID, context: context)
            if let event = resolved, !event.isCompleted {
                triggered.append(event)
                // 用户主动「稍后提醒」写入新 AlertKey（fireDate 时刻）；
                // 2026-11-06 起不再有 300s 自动重提醒，重复提醒只来自用户此操作
                let key = ReminderAlertKey(eventID: record.eventID, alertTime: record.fireDate).encoded
                if !lastAlertedEventIDs.contains(key) {
                    lastAlertedEventIDs.append(key)
                }
                AppLogger.reminder.info("稍后提醒触发 id=\(record.eventID) fireDate=\(Int(record.fireDate.timeIntervalSince1970))")
            }
            // 到期记录不再保留：存活的已转 AlertKey，失效即 GC
        }
        if surviving.count != records.count {
            Self.saveSnoozeRecords(surviving)
        }
        return triggered
    }

    /// 标记事件为完成
    private func markAsCompleted(eventID: String) async {
        // 使用 EventCacheService 的统一上下文，确保与 @Query 同步
        guard let context = EventCacheService.shared.context else { return }

        let descriptor = FetchDescriptor<CachedEvent>(
            predicate: #Predicate { $0.eventID == eventID }
        )

        do {
            // 直查主表；复合 occurrence ID 实例未落库必 miss——回查本体取 isReminder，
            // 仍以复合 ID 走 toggleEventCompleted（内部路由 occurrence 级完成）
            let resolved = try context.fetch(descriptor).first
                ?? CachedEvent.parseOccurrenceID(eventID).flatMap { parts -> CachedEvent? in
                    let baseID = parts.baseID
                    let baseDescriptor = FetchDescriptor<CachedEvent>(
                        predicate: #Predicate { $0.eventID == baseID }
                    )
                    return try? context.fetch(baseDescriptor).first
                }
            if let event = resolved {
                // 使用 CalendarService 的双向同步方法（同时更新 EventKit 和 SwiftData）
                await CalendarService.shared.toggleEventCompleted(
                    eventID: eventID,
                    isCompleted: true,
                    isReminder: event.isReminder
                )
                // D2/G7v2：弹窗完成路径广播缓存变更（徽标即时刷新）
                NotificationCenter.default.post(name: .cachedEventsChanged, object: nil)
                AppLogger.reminder.info("已标记事件完成: \(eventID)")
            }
        } catch {
            AppLogger.reminder.error("标记完成失败: \(String(describing: error))")
        }
    }
    
    /// 将已提醒事件ID持久化到 UserDefaults
    private func persistAlertedEventIDs() {
        UserDefaults.standard.set(lastAlertedEventIDs, forKey: Self.alertedEventIDsKey)
    }

    /// 限制 lastAlertedEventIDs 的大小，避免内存泄漏
    /// 淘汰最早添加的记录（数组头部），保留最近的记录（数组尾部）
    private func trimAlertedEventIDsIfNeeded() {
        if lastAlertedEventIDs.count > maxAlertedEventIDs {
            let overflow = lastAlertedEventIDs.count - maxAlertedEventIDs
            lastAlertedEventIDs.removeFirst(overflow)
            AppLogger.reminder.info("清理了 \(overflow) 个过期提醒记录")
        }
        persistAlertedEventIDs()
    }

    // MARK: - 去重键辅助

    /// BUG-03：去重主体 ID——复合 occurrence ID 归一到 baseID，其余原样返回
    static func alertSubjectID(_ eventID: String) -> String {
        CachedEvent.parseOccurrenceID(eventID)?.baseID ?? eventID
    }

    /// BUG-03：一次性迁移已提醒键——无法解析的旧格式键（无时间戳）丢弃，
    /// 其余重新编码保持秒级格式（幂等）
    static func sanitizedAlertedEventIDs(_ saved: [String]) -> [String] {
        saved.compactMap { ReminderAlertKey(raw: $0)?.encoded }
    }

    /// 判断两个 eventID 是否指向同一提醒主体：复合实例 ID（"baseID|occ:<epoch>"，
    /// R-1 起候选行）归一到 baseID 后比较——静态可测，P2-2 升级兼容的核心判定
    static func sameAlertSubject(_ lhs: String, _ rhs: String) -> Bool {
        alertSubjectID(lhs) == alertSubjectID(rhs)
    }

    /// 判断 (eventID, alertTime) 是否已提醒过：仅 baseID 相同且 alertTime 精确相等。
    /// BUG-03：删除 .distantPast 通配分支——旧格式键已由启动迁移丢弃，
    /// 保留通配会让任意一期命中旧键导致整条序列永久静默
    private func hasAlertedKey(eventID: String, alertTime: Date) -> Bool {
        lastAlertedEventIDs.compactMap { ReminderAlertKey(raw: $0) }.contains { decoded in
            Self.sameAlertSubject(decoded.eventID, eventID) && decoded.alertTime == alertTime
        }
    }
}