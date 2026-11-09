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

/// 循环类型：rawValue 是持久化键（与显示解耦），显示一律用 displayName；
/// 历史版本曾用中文文案作键，存量行由 EventCacheService 启动迁移改写为英文稳定键，
/// init?(rawValue:) 保留中文回落兜底（迁移失败/未迁移的旧库仍可读）
enum RecurrenceType: String, CaseIterable {
    case none = "once"
    case unlimited = "unlimited"
    case hourly = "hourly"      // 仅同步映射使用（EK 无 hourly 表达，由历史间隔推断；不进创建 UI）
    case daily = "daily"
    case weekly = "weekly"
    case monthly = "monthly"
    case yearly = "yearly"
    case custom = "custom"

    /// 存量中文键映射（历史版本持久化值；仅供 init?(rawValue:) 兜底，勿用于显示）
    private static let legacyKeys: [String: RecurrenceType] = [
        "1次": .none, "不限": .unlimited, "每小时": .hourly, "每天": .daily,
        "每周": .weekly, "每月": .monthly, "每年": .yearly, "自定义": .custom
    ]

    /// 重写合成 init?(rawValue:)：英文键优先，中文存量键回落
    init?(rawValue: String) {
        if let matched = Self.allCases.first(where: { $0.rawValue == rawValue }) {
            self = matched
        } else if let legacy = Self.legacyKeys[rawValue] {
            self = legacy
        } else {
            return nil
        }
    }

    /// 显示文案（原中文 rawValue 的显示职责）
    var displayName: String {
        switch self {
        case .none: return "1次"
        case .unlimited: return "不限"
        case .hourly: return "每小时"
        case .daily: return "每天"
        case .weekly: return "每周"
        case .monthly: return "每月"
        case .yearly: return "每年"
        case .custom: return "自定义"
        }
    }
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

// MARK: - ValidityPeriod

/// 任务有效期区间（仅服务/UI 层载体，SwiftData 落库走 CachedEvent 双 Date? 字段）
/// 双端可独立缺省：nil = 该端不限制；闭区间（含端点），精确到时分
/// 存量数据落库值为 00:00:00 / 23:59:59（旧版按天归一化的结果），读取后语义不变
struct ValidityPeriod: Equatable {
    var start: Date?
    var end: Date?
}

// MARK: - CalendarEvent

/// 统一事件展示模型，用于 UI 展示
struct CalendarEvent: Identifiable {
    let id: String
    let title: String
    let startDate: Date?
    let endDate: Date?
    let isAllDay: Bool
    /// 所属日历的 EK identifier（同步插入时按 identifier 匹配日历，
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
    /// 循环规则单一真源（nil = 旧档位按 recurrenceType 推导；每小时/农历仅本地）
    var recurrenceSpec: RecurrenceSpec? = nil
    /// 提醒提前分钟数（0=不提醒）
    let reminderMinutes: Int
    /// 多级提醒提前分钟数组（nil = EK 侧无多级 alarm；与 reminderMinutes.max 同源）
    var reminderOffsets: [Int]? = nil
    /// EK 侧闹钟是否为 absolute（绝对时刻）型：
    /// 应用为 EKReminder 写准点 absolute(due) 闹钟，EK 侧不携带提前量，
    /// 提前提醒真源为缓存 reminderOffsets
    var reminderAlarmIsAbsolute: Bool = false
    /// 用户选择的事件颜色（nil 时使用 calendarColorHex）
    let eventColorHex: String?
    /// EK 事件备注（仅系统日历同步拉取时填充，供 syncEvents 判分类/完成标记，
    /// 避免循环内逐条 eventStore.event(withIdentifier:) 跨进程查询；其余路径为 nil）
    var notes: String? = nil
    /// 智能跳过节假日标记（cachedToCalendarEvent 从缓存透传）
    var skipHolidays: Bool = false
    /// 任务有效期区间（cachedToCalendarEvent 透传；
    /// 仅循环任务有周期语义，两端可独立缺省，nil = 该端不限制）
    var validity: ValidityPeriod? = nil

    /// 是否有明确的开始时间（非全天事件）
    var hasTime: Bool {
        !isAllDay && startDate != nil
    }
}
