//
//  HolidaySkipResolver.swift
//  SwallowCalendar
//
//  智能跳过节假日：休日静默跳过判定纯函数（spec: smart-holiday-skip 语义 v3）
//  语义 v3（2026-10-24 用户定案）：勾选任务 startDate 落休日 → 当天列表不显示、不提醒，
//  任务保留原日期（无顺延改写），由用户自行改期；取消原「顺延至下一工作日」机制
//

import Foundation
import SwiftData
import os

/// 「智能跳过节假日」休日判定器：
/// startDate 落在休日（标题命中休关键词，或周六/周日按休处理——班标识补班日除外）
/// 则当天静默跳过（列表不显示、不提醒）。不修改 startDate 持久值。
enum HolidaySkipResolver {

    /// V-35：休/班标题匹配公共常量（全/半角括号口径，单一真源；
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
        guard let events = try? context?.fetch(descriptor) else {
            // 数据缺失 fail-open：仅周末规则仍生效（确定性规则），平日按工作日照常
            return calendar.isDateInWeekend(date)
        }
        // 「班」标识优先：补班日（含补班周末）视为工作日
        if events.contains(where: { isWorkTitle($0.title) }) { return false }
        if events.contains(where: { isRestTitle($0.title) }) { return true }
        // 周六/周日按休处理
        return calendar.isDateInWeekend(date)
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
