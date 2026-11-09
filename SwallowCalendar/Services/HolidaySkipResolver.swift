//
//  HolidaySkipResolver.swift
//  SwallowCalendar
//
//  智能跳过节假日：休日静默跳过判定纯函数（spec: smart-holiday-skip 语义 v3）
//  语义：勾选任务 startDate 落休日 → 当天列表不显示、不提醒，
//  任务保留原日期（无顺延改写），由用户自行改期
//

import Foundation
import SwiftData
import os

/// 「智能跳过节假日」休日判定器：
/// startDate 落在休日（标题命中休关键词，或周六/周日按休处理——班标识补班日除外）
/// 则当天静默跳过（列表不显示、不提醒）。不修改 startDate 持久值。
enum HolidaySkipResolver {

    /// 休/班标题匹配公共常量（全/半角括号口径，单一真源；
    /// CalendarDayCell 网格休/班标记与本 Resolver 共用，防关键词漂移）
    static let restTitleKeywords = ["假期", "（休）", "(休)"]
    static let workTitleKeywords = ["补班", "（班）", "(班)"]

    /// 标题是否命中休关键词（全/半角括号兼容）
    static func isRestTitle(_ title: String) -> Bool {
        restTitleKeywords.contains { title.contains($0) }
    }

    /// 标题是否命中班关键词（全/半角括号兼容）
    static func isWorkTitle(_ title: String) -> Bool {
        workTitleKeywords.contains { title.contains($0) }
    }

    /// 判断某日是否休日（跳过判定单一入口），判定优先级：
    /// ① 休/班标识最高：当日标题命中「休」关键词 → 休日（跳过）；命中「班」关键词 → 工作日（照常，补班周末属此）；
    /// ② 其次周末两天：周六/周日按休处理（用户需求补充语义，确定性规则不依赖节假日数据）；
    /// ③ 其他：平日无休标识 → 工作日（数据缺失 fail-open 照常，原语义保留）
    /// 限定单日窗口谓词（禁全表）
    static func isRestDay(_ date: Date, context: ModelContext?) -> Bool {
        let calendar = Calendar.current
        let windowStart = calendar.startOfDay(for: date)
        // 日粒度判定缓存优先：
        // 渲染逐行/倒计时逐秒刷新与循环展开逐 occurrence 判定不再逐次查库
        if let context, let cached = cachedVerdict(windowStart, context: context) {
            return cached
        }
        let windowEnd = calendar.date(byAdding: .day, value: 1, to: windowStart)!
        // 「事件覆盖当日」语义（不用 B-24 左边界放宽：全天节假日事件 endDate = 次日 00:00，
        // 放宽会把当日事件泄漏进次日窗口导致误判为休日）：
        // ① 非零长事件严格重叠 [windowStart, windowEnd)；② 零长事件（start==end，提醒映射产物）
        // 归属其开始日当天
        let distantPast = Date.distantPast
        let distantFuture = Date.distantFuture
        let predicate = #Predicate<CachedEvent> { event in
            ((event.startDate ?? distantPast) < windowEnd
                && (event.endDate ?? distantFuture) > windowStart)
                || (event.startDate != nil
                    && (event.startDate ?? distantPast) == (event.endDate ?? distantPast)
                    && (event.startDate ?? distantPast) >= windowStart
                    && (event.startDate ?? distantPast) < windowEnd)
        }
        let descriptor = FetchDescriptor<CachedEvent>(predicate: predicate)
        // 查询失败 fail-open：仅周末规则仍生效（确定性规则），平日按工作日照常
        //（fail-open 非权威判定，不写入缓存）；失败必须落日志
        guard let context,
              let events = CacheFetch.optional(descriptor, in: context, operation: "休/班判定查询") else {
            return calendar.isDateInWeekend(date)
        }
        // 「班」标识优先：补班日（含补班周末）视为工作日
        let verdict: Bool
        if events.contains(where: { isWorkTitle($0.title) }) {
            verdict = false
        } else if events.contains(where: { isRestTitle($0.title) }) {
            verdict = true
        } else {
            // 周六/周日按休处理
            verdict = calendar.isDateInWeekend(date)
        }
        storeVerdict(windowStart, verdict, context: context)
        return verdict
    }

    // MARK: - 日粒度判定缓存

    private static let cacheLock = NSLock()
    /// 判定缓存：按 ModelContext 身份分桶（防多容器/测试串值），键 = 当日零点。
    /// 桶内强持有 context：context 释放后其地址可能被新实例复用，弱键会撞键串值
    private static var dayVerdicts: [ObjectIdentifier: DayVerdictBucket] = [:]
    private static var changeObserver: NSObjectProtocol?

    private struct DayVerdictBucket {
        let context: ModelContext
        var verdicts: [Date: Bool] = [:]
    }

    /// 清空判定缓存（.cachedEventsChanged 回调入口；测试隔离亦可直接调用）
    static func invalidateDayVerdictCache() {
        ensureChangeObserver()
        clearVerdicts()
    }

    private static func clearVerdicts() {
        cacheLock.lock()
        dayVerdicts.removeAll()
        cacheLock.unlock()
    }

    private static func ensureChangeObserver() {
        guard changeObserver == nil else { return }
        // observer token 必须持有，否则 block 注册即释放失效
        changeObserver = NotificationCenter.default.addObserver(
            forName: .cachedEventsChanged, object: nil, queue: nil
        ) { _ in HolidaySkipResolver.clearVerdicts() }
    }

    private static func cachedVerdict(_ day: Date, context: ModelContext) -> Bool? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return dayVerdicts[ObjectIdentifier(context)]?.verdicts[day]
    }

    private static func storeVerdict(_ day: Date, _ verdict: Bool, context: ModelContext) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        let key = ObjectIdentifier(context)
        var bucket = dayVerdicts[key] ?? DayVerdictBucket(context: context)
        bucket.verdicts[day] = verdict
        dayVerdicts[key] = bucket
    }

    /// 批量预热：单次按休/班标题窄查询预载
    /// [from, to) 各日判定，循环展开逐 occurrence 判定退化为内存命中。
    /// 语义与逐日 isRestDay 完全一致：① 班标识日 false；② 休标识日 true；③ 无标识日周末规则。
    /// 覆盖日归属沿用「事件覆盖当日」语义：非零长事件严格重叠日窗口；零长事件归属开始日
    static func warmRestFlags(from: Date, to: Date, context: ModelContext?) {
        guard let context, from < to else { return }
        ensureChangeObserver()
        let calendar = Calendar.current
        let spanStart = calendar.startOfDay(for: from)
        // 取数窗口右界放宽到 to 所在日终：边界日 [d, d+1) 的完整重叠语义与逐日查询一致
        let fetchEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: to))!
        let distantPast = Date.distantPast
        let distantFuture = Date.distantFuture
        // 窗口重叠谓词与逐日 isRestDay 同款；休/班标题过滤放内存做——
        // #Predicate 关键词 OR 链会触发类型检查超时，且避免关键词常量双处同步
        let predicate = #Predicate<CachedEvent> { event in
            ((event.startDate ?? distantPast) < fetchEnd
                && (event.endDate ?? distantFuture) > spanStart)
                || (event.startDate != nil
                    && (event.startDate ?? distantPast) == (event.endDate ?? distantPast)
                    && (event.startDate ?? distantPast) >= spanStart
                    && (event.startDate ?? distantPast) < fetchEnd)
        }
        // 取数失败不预热：后续逐日判定走原查库路径（fail-open 语义不变），失败必须落日志
        let overlapping = CacheFetch.degradeToEmpty(
            FetchDescriptor<CachedEvent>(predicate: predicate),
            in: context,
            operation: "节假日缓存预热查询",
            reason: "预热失败时逐日判定回退原查库路径，结果正确性不变"
        )
        let flagged = overlapping.filter { isRestTitle($0.title) || isWorkTitle($0.title) }
        var restDays = Set<Date>()
        var workDays = Set<Date>()
        for event in flagged {
            let markDay: (Date) -> Void = isWorkTitle(event.title)
                ? { workDays.insert($0) }
                : { restDays.insert($0) }
            // 零长事件归属开始日（取数窗口已保证与 span 重叠）
            if let zs = event.startDate, let ze = event.endDate, zs == ze {
                markDay(calendar.startOfDay(for: zs))
                continue
            }
            // 非零长/开区间：nil 端按逐日谓词的 ±∞ 语义夹进取数窗口
            let s = event.startDate ?? distantPast
            let e = event.endDate ?? distantFuture
            var day = calendar.startOfDay(for: max(s, spanStart))
            let last = min(e, fetchEnd)
            var guardCount = 0
            while day < last, guardCount < 4000 {
                // 逐日窗口判定：start < day+1 且 end > day
                if s < calendar.date(byAdding: .day, value: 1, to: day)!, e > day {
                    markDay(day)
                }
                day = calendar.date(byAdding: .day, value: 1, to: day)!
                guardCount += 1
            }
        }
        // 逐日装配判定并写入缓存：班优先 → 休 → 周末规则
        var day = spanStart
        var assigned = 0
        while day < to, assigned < 40_000 {
            let verdict = workDays.contains(day)
                ? false
                : (restDays.contains(day) ? true : calendar.isDateInWeekend(day))
            storeVerdict(day, verdict, context: context)
            day = calendar.date(byAdding: .day, value: 1, to: day)!
            assigned += 1
        }
    }

    /// 跳过判定便捷入口（各消费点收口，防散落漏改）：
    /// 勾选任务 startDate 落休日（休标识/周末，班标识除外）→ 判定跳过（当天列表不显示、不提醒）；
    /// 未勾选/无日期/班日/工作日 → 照常。仅做判定，不改写 startDate 持久值
    static func isSkipped(of event: CachedEvent, context: ModelContext?) -> Bool {
        guard event.skipHolidays, let start = event.startDate else { return false }
        return isRestDay(start, context: context)
    }

    /// 跳过判定便捷入口（CalendarEvent 重载）：列表层（EventTodoListView/EventItemRow）
    /// 数据类型版本，语义同上
    static func isSkipped(of event: CalendarEvent, context: ModelContext?) -> Bool {
        guard event.skipHolidays, let start = event.startDate else { return false }
        return isRestDay(start, context: context)
    }
}
