//
//  CalendarEvent.swift
//  SwallowCalendar
//

import Foundation

// MARK: - Event Priority

enum EventPriority: Int, CaseIterable {
    case none = 0
    case low = 5
    case medium = 7
    case high = 9

    var displayName: String {
        switch self {
        case .none: return "无"
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        }
    }
}

// MARK: - Recurrence Type

enum RecurrenceType: String, CaseIterable {
    case none = "1次"           // 不重复
    case daily = "每天"
    case weekly = "每周"
    case monthly = "每月"
    case yearly = "每年"
    case custom = "自定义"
}

// MARK: - Event Color

enum EventColor: String, CaseIterable {
    case red = "#FF3B30"
    case orange = "#FF9500"
    case yellow = "#FFCC00"
    case green = "#34C759"
    case blue = "#007AFF"
    case purple = "#AF52DE"
    case pink = "#FF2D55"
    case gray = "#8E8E93"

    var displayName: String {
        switch self {
        case .red: return "红色"
        case .orange: return "橙色"
        case .yellow: return "黄色"
        case .green: return "绿色"
        case .blue: return "蓝色"
        case .purple: return "紫色"
        case .pink: return "粉色"
        case .gray: return "灰色"
        }
    }
}

// MARK: - Event Category

/// 事件分类
enum EventCategory: String, CaseIterable {
    case system = "系统"       // 系统日历
    case subscription = "订阅" // 订阅日历
    case user = "用户"         // 用户创建的事件
}

// MARK: - CalendarEvent

/// 统一事件展示模型，用于 UI 展示
struct CalendarEvent: Identifiable {
    let id: String
    let title: String
    let startDate: Date?
    let endDate: Date?
    let isAllDay: Bool
    let calendarTitle: String
    let calendarColorHex: String
    /// 事件分类：系统、订阅、用户
    let category: EventCategory
    /// 是否已完成
    var isCompleted: Bool
    /// 优先级 (0=无, 1-9, 9最高)，只有用户分类的事件才有优先级
    let priority: Int
    /// 是否来自系统提醒
    let isReminder: Bool
    /// 周期任务组ID（仅周期任务有值）
    let groupId: String?
    /// 周期类型
    let recurrenceType: RecurrenceType

    /// 是否为订阅日历（订阅日历不在用户事件列表中显示）
    var isSubscription: Bool {
        category == .subscription
    }

    /// 是否有明确的开始时间（非全天事件）
    var hasTime: Bool {
        !isAllDay && startDate != nil
    }
    
    /// 是否需要动态倒计时刷新（倒计时 < 1 天且有 startDate）
    var needsDynamicCountdown: Bool {
        guard let start = startDate else { return false }
        let remainingTime = start.timeIntervalSinceNow
        return remainingTime > 0 && remainingTime < 86400 // 大于 0 且小于 1 天
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
        let seconds = Int(interval) % 60

        if days >= 365 {
            let years = days / 365
            let remainDays = days % 365
            return remainDays > 0 ? "\(years)年\(remainDays)天" : "\(years)年"
        } else if days >= 1 {
            return "\(days)天"
        } else if hours >= 1 {
            return "\(hours)小时"
        } else {
            // 小于1小时：显示"X分Y秒"或"X秒"
            if minutes > 0 {
                return "\(minutes)分\(seconds)秒"
            } else {
                return "\(seconds)秒"
            }
        }
    }
}
