//
//  TodayTodoSorter.swift
//  SwallowCalendar
//
//  hover 今天待办弹层：排序与今天判定纯函数（无 AppKit/SwiftData 依赖，可沙箱直编验证）
//

import Foundation

enum TodayTodoSorter {

    /// 弹层排序（2026-11-12 口径变更：与主界面一致）：
    /// 1. 分组——有时间未完成(0) < 无时间未完成(1) < 已完成(2)
    ///    （无到期事项无紧迫性排末尾，不再置顶）
    /// 2. 组内按 startDate 升序，nil 视为最早
    /// 3. 同键保持输入顺序（稳定排序）
    static func sort(
        _ events: [CachedEvent],
        now: Date,
        calendar: Calendar = .current
    ) -> [CachedEvent] {
        events.enumerated().sorted { l, r in
            let lGroup = group(of: l.element)
            let rGroup = group(of: r.element)
            if lGroup != rGroup { return lGroup < rGroup }
            let lTime = l.element.startDate ?? .distantPast
            let rTime = r.element.startDate ?? .distantPast
            if lTime != rTime { return lTime < rTime }
            return l.offset < r.offset
        }.map { $0.element }
    }

    /// 今天判定：nil startDate 恒算今天（随手记纯待办置顶显示）；否则同天判定
    static func isToday(
        _ startDate: Date?,
        now: Date,
        calendar: Calendar = .current
    ) -> Bool {
        guard let startDate else { return true }
        return calendar.isDate(startDate, inSameDayAs: now)
    }

    /// 超时判定（口径经用户确认）：
    /// - 非全天：开始时间已过、未完成才算超时
    /// - 全天：归属日早于今天才算超时——全天任务 startDate 为当天零点，
    ///   按 start < now 判会让当天全天事项整天误标「已过期」
    /// - 无时间任务无期限，永不超时；已完成任务不显示超时（已置灰）
    /// - 非全天严格小于：开始时间恰好等于当前时刻不算（与主面板 EventItemRow 口径一致）
    static func isOverdue(_ event: CachedEvent, now: Date, calendar: Calendar = .current) -> Bool {
        guard !event.isCompleted, let start = event.startDate else { return false }
        if event.isAllDay {
            return start < calendar.startOfDay(for: now)
        }
        return start < now
    }

    /// CalendarEvent 版本（主界面待办列表）：字段名与 CachedEvent 一致，共用同一口径
    static func isOverdue(_ event: CalendarEvent, now: Date, calendar: Calendar = .current) -> Bool {
        guard !event.isCompleted, let start = event.startDate else { return false }
        if event.isAllDay {
            return start < calendar.startOfDay(for: now)
        }
        return start < now
    }

    /// 是否渲染倒计时胶囊（isOverdue=false 且未完成时的兜底口径）：
    /// - 带时间任务：距开始时刻的剩余有意义，恒渲染（remaining<=0 已被 isOverdue 红字分支拦截）
    /// - 全天任务：倒计时指向归属日零点，当天全天已「进行中」且 remaining=零点−now<0，
    ///   会被 CountdownFormatter 渲染成「已过期」胶囊，与「当天整天不算过期」矛盾——当天全天不渲染
    /// 参数化 (isAllDay, startDate) 而非整个事件，CachedEvent/CalendarEvent 两个 UI 模型共用
    static func showsCountdown(
        isAllDay: Bool,
        startDate: Date?,
        now: Date,
        calendar: Calendar = .current
    ) -> Bool {
        guard let start = startDate else { return false }
        if isAllDay {
            return !calendar.isDate(start, inSameDayAs: now)
        }
        return true
    }

    /// 实例是否已开始（startDate <= now；无到期时间视为已开始）。
    /// 提醒完成标记仅作用于已开始实例——未开始实例被提前标完成会错误推进周期任务序列
    static func hasStarted(startDate: Date?, now: Date) -> Bool {
        (startDate ?? now) <= now
    }

    /// 分组键：有时间未完成 0 / 无时间未完成 1 / 已完成 2（2026-11-12 口径变更）
    private static func group(of event: CachedEvent) -> Int {
        event.isCompleted ? 2 : (event.startDate == nil ? 1 : 0)
    }
}
