//
//  TodayTodoSorter.swift
//  SwallowCalendar
//
//  hover 今天待办弹层：排序与今天判定纯函数（无 AppKit/SwiftData 依赖，可沙箱直编验证）
//

import Foundation

enum TodayTodoSorter {

    /// 弹层排序（spec AC-1）：
    /// 1. 分组——无时间未完成(0) < 有时间未完成(1) < 已完成(2)
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

    /// 超时判定（口径经用户确认）：仅「带时间（非全天）且开始时间已过、未完成」才算超时
    /// - 全天任务 startDate 为当天零点，当天不算超时（等价于过期提醒口径「全天需早于今天零点」）
    /// - 无时间任务无期限，永不超时；已完成任务不显示超时（已置灰）
    /// - 严格小于：开始时间恰好等于当前时刻不算（与主面板 EventItemRow 口径一致）
    static func isOverdue(_ event: CachedEvent, now: Date) -> Bool {
        guard !event.isCompleted,
              let start = event.startDate,
              !event.isAllDay else { return false }
        return start < now
    }

    /// 分组键：无时间未完成 0 / 有时间未完成 1 / 已完成 2
    private static func group(of event: CachedEvent) -> Int {
        event.isCompleted ? 2 : (event.startDate == nil ? 0 : 1)
    }
}
