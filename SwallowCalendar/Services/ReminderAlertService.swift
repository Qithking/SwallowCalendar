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
/// 旧格式（无 "|"，仅 eventID）惰性兼容：alertTime 回退 .distantPast，
/// 匹配语义为"该事件已提醒过"；孤儿键不迁移，保留至 trim（1000 上限）自然淘汰
struct ReminderAlertKey: Equatable {
    let eventID: String
    let alertTime: Date

    init(eventID: String, alertTime: Date) {
        self.eventID = eventID
        self.alertTime = alertTime
    }

    /// 解码持久化串：时间戳取末段 "|" 之后（eventID 本身不含 "|"，末段分割对
    /// 新旧格式均正确；时间戳段非法时按旧格式兼容处理）
    init(raw: String) {
        if let idx = raw.lastIndex(of: "|"),
           let ts = TimeInterval(raw[raw.index(after: idx)...]) {
            self.eventID = String(raw[..<idx])
            self.alertTime = Date(timeIntervalSince1970: ts)
        } else {
            self.eventID = raw
            self.alertTime = .distantPast
        }
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
    private var lastAlertedEventIDs: [String] = []
    /// 持久化已提醒事件ID的 UserDefaults 键
    private static let alertedEventIDsKey = "ReminderAlertService.lastAlertedEventIDs"
    /// 已提醒事件ID的最大缓存数量
    private let maxAlertedEventIDs = 1000
    /// 持久化上次检查时间的 UserDefaults 键（B-14）
    private static let lastCheckTimeKey = "ReminderAlertService.lastCheckTime"
    /// 上次检查时间（B-14：挂起/睡眠恢复后以"上次检查~now"为提醒窗口，避免漏提醒）
    private var lastCheckTime: Date?
    
    private init() {
        // 从 UserDefaults 恢复已提醒事件ID，避免应用重启后重复弹窗
        if let saved = UserDefaults.standard.stringArray(forKey: Self.alertedEventIDsKey) {
            self.lastAlertedEventIDs = saved
        }
        // B-14：恢复上次检查时间，重启后窗口下界不回退到"无记录"状态
        let savedTime = UserDefaults.standard.double(forKey: Self.lastCheckTimeKey)
        if savedTime > 0 {
            self.lastCheckTime = Date(timeIntervalSince1970: savedTime)
        }
    }
    
    /// 配置服务
    func configure(with container: ModelContainer) {
        // modelContainer 已不再需要，保留方法以兼容调用方
    }
    
    /// 启动提醒检查
    func startMonitoring() {
        stopMonitoring()
        
        // 确保在主线程上执行检查
        DispatchQueue.main.async { [weak self] in
            // 不要立即检查过期事项，等待数据同步完成后由外部调用 checkExpiredEvents()
            // 每分钟检查一次是否有待办事项到期
            self?.timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task {
                    await self?.checkDueEvents()
                }
            }
        }
    }
    
    /// 检查过期事项（供数据同步完成后调用）
    /// 启动时的检查会忽略 lastAlertedEventIDs 过滤，确保过期事项始终被提示
    func checkExpiredEvents() async {
        await checkDueEvents(includeExpired: true, ignoreAlertedCache: true)
        AppLogger.reminder.info("数据同步后过期事项检查完成")
    }
    
    /// 停止提醒检查
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }
    
    /// 检查到期的待办事项
    /// - Parameters:
    ///   - includeExpired: 是否包含已过期的事项（仅在应用启动时使用）
    ///   - ignoreAlertedCache: 是否忽略已提醒缓存（启动时为 true，确保过期事项始终提示）
    private func checkDueEvents(includeExpired: Bool = false, ignoreAlertedCache: Bool = false) async {
        // 使用 EventCacheService 的上下文，确保与待办列表显示的数据一致
        guard let context = EventCacheService.shared.context else {
            AppLogger.reminder.warning("EventCacheService 未配置")
            return
        }
        let now = Date()
        let calendar = Calendar.current

        // 先获取所有未完成的用户事件，然后在内存中过滤日期
        // 这种方式可以避免 SwiftData Predicate 的复杂语法问题
        // EventCategory.user.rawValue 的值是 "用户"（中文字符串）
        let userCategory = "用户"

        // B-27：把提醒时间窗口换算为 startDate 窗口下沉到谓词粗筛，避免每分钟全表拉取。
        // alertTime = startDate - reminderMinutes*60（reminderMinutes ≥ 0，UI 上限 1440 分钟），
        // 因此 alertTime ∈ [windowLower, now] 的必要条件是
        // startDate ∈ [windowLower, now + 1440 分钟]，精确判定仍由下方内存过滤完成。
        // 常规检查下界为 B-14 的 lastCheckTime 窗口（无记录回退 90 秒）；
        // includeExpired 需覆盖全部已过期提醒，下界放开
        let maxReminderLeadSeconds: TimeInterval = 1440 * 60
        let fetchUpperBound = now.addingTimeInterval(maxReminderLeadSeconds)
        let windowStart = lastCheckTime ?? calendar.date(byAdding: .second, value: -90, to: now)!
        let fetchLowerBound = includeExpired ? Date.distantPast : windowStart
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
            // 检查把 base 行替换为同源展开实例，与主面板判定源对齐（仅启动路径，常规
            // 60s 轮询窗口语义不变）
            if includeExpired {
                allUserEvents = Self.expiredCheckCandidates(
                    rawEvents: allUserEvents,
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
                    // 未设置提醒（无正档位）的事项不弹窗
                    // B-14：窗口下界用持久化的上次检查时间——应用挂起/睡眠超 90 秒后，
                    // 固定 90 秒窗口会滤掉挂起期间到期的事项导致漏提醒；
                    // 无记录时回退 90 秒窗口（配合 60 秒定时器确保不遗漏）
                    alertTimes = offsets.compactMap { offset in
                        guard offset > 0 else { return nil }
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
                // 5分钟后允许再次提醒
                DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in
                    guard let self else { return }
                    // B-29：移除后同步持久化——原实现只改内存数组，重启后
                    // UserDefaults 仍含旧 ID，5 分钟重提醒窗口失效
                    for event in mergedEvents {
                        // 按事件匹配移除（含新键前缀与旧格式键），300 秒后允许再次提醒
                        self.lastAlertedEventIDs.removeAll { raw in
                            ReminderAlertKey(raw: raw).eventID == event.eventID
                        }
                    }
                    self.persistAlertedEventIDs()
                }
            }
            // B-14：本次检查已覆盖到 now，记录检查时间作为下次检查（含挂起恢复后）的窗口下界；
            // 仅在 fetch 成功后更新，失败时保留旧值以免跳过失败区间的提醒
            lastCheckTime = now
            UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Self.lastCheckTimeKey)
        } catch {
            AppLogger.reminder.error("检查到期事件失败: \(String(describing: error))")
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
                // snooze 重提醒写入新 AlertKey（fireDate 时刻）；5 分钟重提醒机制照常运行，
                // 两窗口重叠致同事项短时重复提醒由合并弹窗替换机制收敛为单窗（已定案行为）
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

    /// 判断 (eventID, alertTime) 是否已提醒过：新键精确匹配 alertTime；
    /// 旧格式键（解码 alertTime == .distantPast）惰性兼容——视为该事件已提醒过
    private func hasAlertedKey(eventID: String, alertTime: Date) -> Bool {
        lastAlertedEventIDs.contains { raw in
            let decoded = ReminderAlertKey(raw: raw)
            return decoded.eventID == eventID &&
                   (decoded.alertTime == alertTime || decoded.alertTime == .distantPast)
        }
    }
}