//
//  CalendarEvent.swift
//  SwallowCalendar
//

import Foundation

/// 统一事件展示模型，用于 UI 展示
struct CalendarEvent: Identifiable {
    let id: String
    let title: String
    let startDate: Date?
    let endDate: Date?
    let isAllDay: Bool
    let calendarTitle: String
    let calendarColorHex: String
    let source: EventSource

    enum EventSource {
        case system       // 系统日历
        case customICS    // 自定义ICS
    }

    /// 是否有明确的开始时间（非全天事件）
    var hasTime: Bool {
        !isAllDay && startDate != nil
    }

    /// 倒计时文本
    var countdownText: String {
        guard let start = startDate else { return "" }
        let now = Date()
        guard start > now else { return "已过期" }
        let interval = start.timeIntervalSince(now)
        let days = Int(interval) / 86400
        let hours = (Int(interval) % 86400) / 3600
        let minutes = (Int(interval) % 3600) / 60

        if days >= 365 {
            let years = days / 365
            let remainDays = days % 365
            return remainDays > 0 ? "\(years)年\(remainDays)天" : "\(years)年"
        } else if days >= 1 {
            return "\(days)天"
        } else if hours >= 1 {
            return "\(hours)小时"
        } else {
            return "\(max(minutes, 1))分钟"
        }
    }
}
