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
    case unlimited = "不限"     // 不限次数（每天重复，无结束日期）
    case hourly = "每小时"      // 仅同步映射使用（EK 无 hourly 表达，由历史间隔推断；不进创建 UI）
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

// MARK: - ValidityPeriod（spec/task-validity-period AC-1~AC-6）

/// 任务有效期区间（仅服务/UI 层载体，SwiftData 落库走 CachedEvent 双 Date? 字段）
/// 双端可独立缺省：nil = 该端不限制；闭区间，天粒度归一化
struct ValidityPeriod: Equatable {
    var start: Date?
    var end: Date?

    /// 开始端归一化为当天 00:00:00
    var normalizedStartDate: Date? {
        start.map { Calendar.current.startOfDay(for: $0) }
    }

    /// 结束端归一化为当天 23:59:59
    var normalizedEndDate: Date? {
        end.map { Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: $0) ?? $0 }
    }
}

// MARK: - CalendarEvent

/// 统一事件展示模型，用于 UI 展示
struct CalendarEvent: Identifiable {
    let id: String
    let title: String
    let startDate: Date?
    let endDate: Date?
    let isAllDay: Bool
    /// 所属日历的 EK identifier（B-9：同步插入时按 identifier 匹配日历，
    /// 避免 title 同名/本地化差异取错日历）
    let calendarID: String
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
    /// 周期类型
    let recurrenceType: RecurrenceType
    /// 提醒提前分钟数（0=不提醒）
    let reminderMinutes: Int
    /// 多级提醒提前分钟数组（plan 步骤 7，nil = EK 侧无多级 alarm；与 reminderMinutes.max 同源）
    var reminderOffsets: [Int]? = nil
    /// 用户选择的事件颜色（nil 时使用 calendarColorHex）
    let eventColorHex: String?
    /// B-25：EK 事件备注（仅系统日历同步拉取时填充，供 syncEvents 判分类/完成标记，
    /// 避免循环内逐条 eventStore.event(withIdentifier:) 跨进程查询；其余路径为 nil）
    var notes: String? = nil
    /// 智能跳过节假日标记（plan 步骤①，cachedToCalendarEvent 从缓存透传）
    var skipHolidays: Bool = false
    /// 任务有效期区间（spec/task-validity-period AC-6，cachedToCalendarEvent 透传；
    /// 仅循环任务有周期语义，两端可独立缺省，nil = 该端不限制）
    var validity: ValidityPeriod? = nil

    /// 是否有明确的开始时间（非全天事件）
    var hasTime: Bool {
        !isAllDay && startDate != nil
    }
}
