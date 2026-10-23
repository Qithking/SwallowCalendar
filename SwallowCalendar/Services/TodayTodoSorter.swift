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

    /// 分组键：无时间未完成 0 / 有时间未完成 1 / 已完成 2
    private static func group(of event: CachedEvent) -> Int {
        event.isCompleted ? 2 : (event.startDate == nil ? 0 : 1)
    }
}
