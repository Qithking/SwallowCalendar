//
//  CalendarService.swift
//  SwallowCalendar
//

import EventKit
import SwiftUI
import SwiftData
import os

@Observable
final class CalendarService {
    static let shared = CalendarService()

    private let eventStore = EKEventStore()
    var authorizationStatus: EKAuthorizationStatus = .notDetermined
    var reminderAuthorizationStatus: EKAuthorizationStatus = .notDetermined
    var calendars: [EKCalendar] = []
    var isLoading = false
    
    /// 事件缓存服务
    let cacheService = EventCacheService.shared

    // internal 供测试 @testable 使用
    init() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        reminderAuthorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
    }

    // MARK: - Public Methods

    // MARK: - Authorization

    /// 请求 EventKit 权限
    /// - Parameter requestReminders: S-7：是否同时请求提醒权限——提醒同步默认关闭，
    ///   关闭时不应无条件索要提醒 fullAccess
    /// 返回 (日历授权成功, 提醒授权成功)
    @MainActor
    func requestAccess(requestReminders: Bool) async -> (calendar: Bool, reminder: Bool) {
        do {
            // 按需请求：日历必请求，提醒仅在开启同步时请求
            let eventResult = try await eventStore.requestFullAccessToEvents()
            var reminderResult = false
            if requestReminders {
                reminderResult = try await eventStore.requestFullAccessToReminders()
                reminderAuthorizationStatus = reminderResult ? .fullAccess : .denied
            } else {
                // 未请求提醒权限时保留现有状态，不覆盖为 denied
                reminderResult = reminderAuthorizationStatus == .fullAccess
            }

            authorizationStatus = eventResult ? .fullAccess : .denied

            if eventResult {
                loadCalendars()
            }

            return (eventResult, reminderResult)
        } catch {
            authorizationStatus = .denied
            if requestReminders {
                reminderAuthorizationStatus = .denied
            }
            return (false, false)
        }
    }

    /// 打开系统设置中的提醒权限页面
    func openReminderSettings() {
        // 尝试打开系统设置 - 隐私与安全性 - 提醒事项
        if let url = URL(string: "x-apple.systempreferences://com.apple.preference.security?Privacy_Reminders") {
            if NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - Calendars

    @MainActor
    func loadCalendars() {
        calendars = eventStore.calendars(for: .event)
    }

    /// 获取已启用的日历（根据用户偏好过滤）
    /// - 新用户（preferences 为空）：返回所有系统日历
    /// - 所有日历已关闭（enabledIDs 为空）：返回空数组，不同步任何系统日历数据
    /// - 有开启的日历：只返回开启的日历
    func enabledCalendars(preferences: [CalendarPreference]) -> [EKCalendar] {
        let enabledIDs = Set(preferences.filter(\.isEnabled).map(\.calendarID))

        if preferences.isEmpty {
            // 新用户，还没有任何偏好配置，返回所有系统日历（包括系统订阅日历，统一归为系统分类）
            return calendars
        }

        if enabledIDs.isEmpty {
            // 所有日历都已关闭，返回空数组（不同步任何系统日历数据）
            return []
        }

        // 只返回用户明确开启的日历
        return calendars.filter { enabledIDs.contains($0.calendarIdentifier) }
    }

    // MARK: - Events

    /// 获取指定日期范围的事件
    func fetchEvents(from startDate: Date, to endDate: Date, calendars: [EKCalendar]? = nil) -> [CalendarEvent] {
        let predicate = eventStore.predicateForEvents(
            withStart: startDate,
            end: endDate,
            calendars: calendars
        )
        let ekEvents = eventStore.events(matching: predicate)
        return ekEvents.map { mapToCalendarEvent($0) }
    }
    
    /// 从缓存获取指定日期范围的事件（优先使用缓存，加快启动速度）
    /// - Note: 默认不包含无到期时间的系统提醒（用于日历视图）
    @MainActor
    func fetchCachedEvents(from startDate: Date, to endDate: Date, calendars: [EKCalendar]? = nil, includeNoDateReminders: Bool = false) -> [CalendarEvent] {
        let cached = cacheService.getEvents(from: startDate, to: endDate, calendars: calendars, includeNoDateReminders: includeNoDateReminders)
        return cached.map { cachedToCalendarEvent($0) }
    }

    /// 获取某天的事件
    func fetchEvents(for date: Date, calendars: [EKCalendar]? = nil) -> [CalendarEvent] {
        let (start, end) = dayRange(for: date)
        return fetchEvents(from: start, to: end, calendars: calendars)
    }
    
    /// 从缓存获取某天的事件（优先使用缓存）
    /// - Note: 默认不包含无到期时间的系统提醒（用于日历视图）
    @MainActor
    func fetchCachedEvents(for date: Date, calendars: [EKCalendar]? = nil, includeNoDateReminders: Bool = false) -> [CalendarEvent] {
        let cached = cacheService.getEvents(for: date, calendars: calendars, includeNoDateReminders: includeNoDateReminders)
        return cached.map { cachedToCalendarEvent($0) }
    }

    /// 从缓存获取全天事件
    /// - Note: 包含无到期时间的系统提醒（用于待办列表）
    @MainActor
    func fetchCachedAllDayEvents(from startDate: Date, to endDate: Date, calendars: [EKCalendar]? = nil) -> [CalendarEvent] {
        var events = fetchCachedEvents(from: startDate, to: endDate, calendars: calendars, includeNoDateReminders: true)
        events = events.filter(\.isAllDay)
        events.sort { $0.startDate ?? .distantFuture < $1.startDate ?? .distantFuture }
        return events
    }

    // MARK: - Reminders

    /// 获取系统提醒（待办事项）
    /// - Parameters:
    ///   - includeCompleted: 是否包含已完成的提醒，默认 false
    ///   - from: 可选的开始日期，用于过滤有到期时间的提醒
    ///   - to: 可选的结束日期，用于过滤有到期时间的提醒
    /// - Note: 没有到期时间的提醒不受日期范围限制，始终返回
    func fetchReminders(includeCompleted: Bool = false, from: Date? = nil, to: Date? = nil) async -> [CalendarEvent] {
        guard reminderAuthorizationStatus == .fullAccess else {
            return []
        }

        let predicate = eventStore.predicateForReminders(in: nil)

        return await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                let mappedReminders = reminders?.compactMap { reminder -> CalendarEvent? in
                    // 过滤已完成项（根据参数决定）
                    if !includeCompleted && reminder.isCompleted {
                        return nil
                    }
                    
                    // 判断是否有到期时间
                    if let dueDate = reminder.dueDateComponents?.date {
                        // 有到期时间的提醒：按照日期范围过滤
                        if let start = from, dueDate < start {
                            return nil
                        }
                        if let end = to, dueDate > end {
                            return nil
                        }
                        return self.mapReminderToCalendarEvent(reminder, dueDate: dueDate)
                    } else {
                        // 没有到期时间的提醒：不受日期范围限制，直接返回
                        return self.mapReminderToCalendarEvent(reminder, dueDate: nil)
                    }
                } ?? []

                continuation.resume(returning: mappedReminders)
            }
        }
    }

    /// 通过 eventID 全量查找 EKReminder 对象
    /// 用于 calendarItem(withIdentifier:) 查不到已完成 iCloud 提醒时的兜底
    private func fetchReminderObject(byID id: String) async -> EKReminder? {
        let predicate = eventStore.predicateForReminders(in: nil)
        return await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders?.first { $0.calendarItemIdentifier == id })
            }
        }
    }

    /// 将 EKReminder 转换为 CalendarEvent
    private func mapReminderToCalendarEvent(_ reminder: EKReminder, dueDate: Date?) -> CalendarEvent {
        let isAllDay: Bool
        if dueDate != nil {
            isAllDay = reminder.dueDateComponents?.hour == nil && reminder.dueDateComponents?.minute == nil
        } else {
            isAllDay = true  // 无到期时间的提醒视为全天事件
        }
        return CalendarEvent(
            id: reminder.calendarItemIdentifier,
            title: reminder.title ?? "",
            startDate: dueDate,
            endDate: dueDate,
            isAllDay: isAllDay,
            calendarID: reminder.calendar?.calendarIdentifier ?? "",
            calendarTitle: reminder.calendar?.title ?? "提醒",
            calendarColorHex: reminder.calendar?.cgColor?.hexString ?? "#FF9500",
            category: .user,
            isCompleted: reminder.isCompleted,
            priority: 0,
            isReminder: true,
            groupId: nil,
            recurrenceType: .none,
            reminderMinutes: Self.extractReminderMinutes(from: reminder.alarms),
            reminderOffsets: Self.extractReminderOffsets(from: reminder.alarms),
            eventColorHex: nil
        )
    }

    /// 从 EKAlarm 数组中提取最早的提醒提前分钟数
    private static func extractReminderMinutes(from alarms: [EKAlarm]?) -> Int {
        guard let alarms = alarms else { return 0 }
        var maxMinutes = 0
        for alarm in alarms {
            // relativeOffset < 0 表示在事件之前提醒
            if alarm.relativeOffset < 0 {
                let minutes = Int(-alarm.relativeOffset / 60)
                if minutes > maxMinutes {
                    maxMinutes = minutes
                }
            }
        }
        return maxMinutes
    }

    /// 从 EKAlarm 数组提取完整提醒提前分钟数组（多级，plan 步骤 7）
    /// 与 extractReminderMinutes 同口径（仅相对偏移 alarm）；去重升序；
    /// 无有效 alarm 返回 nil（未设置多级语义）
    static func extractReminderOffsets(from alarms: [EKAlarm]?) -> [Int]? {
        guard let alarms else { return nil }
        let offsets = Set(alarms.compactMap { alarm -> Int? in
            guard alarm.relativeOffset < 0 else { return nil }
            return Int(-alarm.relativeOffset / 60)
        }).sorted()
        return offsets.isEmpty ? nil : offsets
    }

    /// 生成 EKAlarm 数组：多级 offsets 非空时逐档生成；否则按单级 minutes 兼容口径
    private static func makeAlarms(offsets: [Int]?, minutes: Int?) -> [EKAlarm] {
        if let offsets, !offsets.isEmpty {
            return offsets.map { EKAlarm(relativeOffset: TimeInterval(-$0 * 60)) }
        }
        if let minutes, minutes > 0 {
            return [EKAlarm(relativeOffset: TimeInterval(-minutes * 60))]
        }
        return []
    }

    // MARK: - CRUD

    /// 创建日历事件或提醒
    /// - Note: 如果 asReminder 为 true，则创建到系统提醒；否则创建到系统日历
    /// - Note: 如果是周期任务，会生成5个实例
    @MainActor
    func createEvent(
        title: String,
        startDate: Date,
        endDate: Date?,
        isAllDay: Bool,
        calendar: EKCalendar?,
        priority: EventPriority? = nil,
        recurrence: RecurrenceType? = nil,
        reminderMinutes: Int? = nil,
        reminderOffsets: [Int]? = nil,
        category: EventCategory = .system,
        asReminder: Bool = false,
        isLunar: Bool = false,
        color: EventColor? = nil
    ) throws {
        let recurrenceType = recurrence ?? .none
        
        // 周期任务需要确保时间在当前时间之后
        var finalStartDate = startDate
        var finalEndDate = endDate
        if recurrenceType != .none {
            // E-4：全天事件的 startDate=当日 00:00，恒早于 Date()，
            // 会把当天创建的"每天"全天事项首实例错误推进到明天；
            // 全天只需早于今天零点才算已过期，带时间保持 <= 当前时刻
            let isOverdue = isAllDay
                ? startDate < Calendar.current.startOfDay(for: Date())
                : startDate <= Date()
            if isOverdue {
                // 周期任务：如果时间已过，推进到下一个周期
                finalStartDate = CalendarService.advanceRecurrenceDate(startDate, recurrenceType: recurrenceType)
                
                // 同时推进 endDate（如果有）
                if let ed = endDate {
                    let timeDiff = ed.timeIntervalSince(startDate)
                    finalEndDate = finalStartDate.addingTimeInterval(timeDiff)
                }
            }
        }
        
        // 如果是周期任务，生成5个实例
        if recurrenceType != .none {
            try createRecurringEvents(
                title: title,
                baseDate: finalStartDate,
                endDate: finalEndDate,
                isAllDay: isAllDay,
                calendar: calendar,
                priority: priority,
                recurrenceType: recurrenceType,
                reminderMinutes: reminderMinutes,
                category: category,
                asReminder: asReminder,
                isLunar: isLunar,
                color: color
            )
        } else {
            // 非周期任务，创建一个（允许过去时间）
            if asReminder {
                try createReminder(
                    title: title,
                    dueDate: startDate,
                    isAllDay: isAllDay,
                    priority: priority,
                    recurrence: nil,
                    reminderMinutes: reminderMinutes,
                    color: color
                )
            } else {
                try createCalendarEvent(
                    title: title,
                    startDate: startDate,
                    endDate: endDate,
                    isAllDay: isAllDay,
                    calendar: calendar,
                    priority: priority,
                    recurrence: nil,
                    reminderMinutes: reminderMinutes,
                    category: category,
                    color: color
                )
            }
        }
    }
    
    /// 创建周期任务的5个实例
    @MainActor
    private func createRecurringEvents(
        title: String,
        baseDate: Date,
        endDate: Date?,
        isAllDay: Bool,
        calendar: EKCalendar?,
        priority: EventPriority? = nil,
        recurrenceType: RecurrenceType,
        reminderMinutes: Int? = nil,
        reminderOffsets: [Int]? = nil,
        category: EventCategory,
        asReminder: Bool,
        isLunar: Bool,
        color: EventColor? = nil
    ) throws {
        // 生成5个日期
        let dates = generateRecurringDates(
            baseDate: baseDate,
            recurrenceType: recurrenceType,
            isLunar: isLunar
        )
        
        guard !dates.isEmpty else { return }
        
        // 生成组ID
        let groupId = UUID().uuidString
        
        // 创建每个实例
        for (index, date) in dates.enumerated() {
            // 全天事件的结束日期是第二天
            let eventEndDate: Date? = {
                if isAllDay {
                    return Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: date))
                } else {
                    return endDate ?? date.addingTimeInterval(3600)
                }
            }()
            
            if asReminder {
                try createReminderWithGroupInfo(
                    title: title,
                    dueDate: date,
                    isAllDay: isAllDay,
                    priority: priority,
                    groupId: groupId,
                    groupIndex: index,
                    recurrenceType: recurrenceType,
                    isLunar: isLunar,
                    reminderMinutes: reminderMinutes,
                    color: color
                )
            } else {
                try createCalendarEventWithGroupInfo(
                    title: title,
                    startDate: date,
                    endDate: eventEndDate,
                    isAllDay: isAllDay,
                    calendar: calendar,
                    priority: priority,
                    reminderMinutes: reminderMinutes,
                    category: category,
                    groupId: groupId,
                    groupIndex: index,
                    recurrenceType: recurrenceType,
                    isLunar: isLunar,
                    color: color
                )
            }
        }
    }
    
    /// 创建系统日历事件
    @MainActor
    private func createCalendarEvent(
        title: String,
        startDate: Date,
        endDate: Date?,
        isAllDay: Bool,
        calendar: EKCalendar?,
        priority: EventPriority? = nil,
        recurrence: RecurrenceType? = nil,
        reminderMinutes: Int? = nil,
        reminderOffsets: [Int]? = nil,
        category: EventCategory = .system,
        color: EventColor? = nil
    ) throws {
        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = startDate
        // 全天事件的结束日期必须是第二天，否则EventKit会报错
        if isAllDay {
            event.endDate = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: startDate)) ?? startDate.addingTimeInterval(86400)
        } else {
            let calculatedEndDate = endDate ?? startDate.addingTimeInterval(3600)
            // 确保 endDate > startDate
            if calculatedEndDate <= startDate {
                event.endDate = startDate.addingTimeInterval(3600)
            } else {
                event.endDate = calculatedEndDate
            }
        }
        event.isAllDay = isAllDay
        let targetCalendar = calendar ?? eventStore.defaultCalendarForNewEvents ?? calendars.first
        event.calendar = targetCalendar

        // 设置重复规则
        if let recurrence = recurrence, recurrence != .none {
            let freq: EKRecurrenceFrequency
            switch recurrence {
            case .daily, .unlimited: freq = .daily
            case .weekly: freq = .weekly
            case .monthly: freq = .monthly
            case .yearly: freq = .yearly
            case .none, .custom: freq = .daily
            }
            let rule = EKRecurrenceRule(recurrenceWith: freq, interval: 1, end: nil)
            event.addRecurrenceRule(rule)
        }

        // 设置提醒（仅当用户指定时才添加）：多级 offsets 优先，单级 minutes 兼容
        event.alarms = Self.makeAlarms(offsets: reminderOffsets, minutes: reminderMinutes)

        guard event.calendar != nil else {
            throw EventError.noCalendarAvailable
        }
        
        // B-5：用户分类事件一律打来源标记（与 syncEventsToSystem 开关无关）。
        // 原因：事件总是写入系统日历，若不打标记，清缓存后 syncEvents 会将其
        // 误归为 .system，系统日历侧删除时缓存会被连带误删（.user 本应跳过）。
        if category == .user {
            event.notes = "此事项来自SwallowCalendar应用"
        }
        
        try eventStore.save(event, span: .thisEvent)
        
        // 保存到本地缓存
        if let context = cacheService.context {
            let cached = CachedEvent(
                eventID: event.eventIdentifier,
                title: event.title ?? "",
                startDate: event.startDate,
                endDate: event.endDate,
                isAllDay: event.isAllDay,
                calendarID: event.calendar.calendarIdentifier,
                calendarTitle: event.calendar.title,
                calendarColorHex: event.calendar.cgColor?.hexString ?? "#007AFF",
                category: category,
                priority: priority?.rawValue ?? 0,
                reminderMinutes: reminderMinutes ?? 0,
                eventColorHex: color?.rawValue
            )
            // 多级提醒：经 setter 写入以维护硬不变量 reminderMinutes == offsets.max()
            if let offsets = reminderOffsets, !offsets.isEmpty {
                cached.reminderOffsets = offsets
            }
            context.insert(cached)
            do {
                try context.save()
            } catch {
                AppLogger.sync.error("缓存同步失败: \(String(describing: error))")
            }
        }
    }
    
    /// B-33：EventPriority（9=最高）→ EKReminder.priority（1=最高、9=最低、0=无）语义映射
    private static func ekPriority(from priority: EventPriority?) -> Int {
        // 先解包再 switch：EventPriority 自带 .none case，对 Optional 直接 switch 时
        // `case .none` 被解析为 Optional.none（与 nil 重复），.some(EventPriority.none)
        // 未覆盖会导致运行时崩溃，且穷尽性判定依赖编译器版本
        guard let priority else { return 0 }
        switch priority {
        case .high: return 1
        case .medium: return 5
        case .low: return 9
        case .none: return 0
        }
    }
    
    /// 创建系统提醒
    @MainActor
    private func createReminder(
        title: String,
        dueDate: Date,
        isAllDay: Bool,
        priority: EventPriority? = nil,
        recurrence: RecurrenceType? = nil,
        reminderMinutes: Int? = nil,
        reminderOffsets: [Int]? = nil,
        color: EventColor? = nil
    ) throws {
        guard reminderAuthorizationStatus == .fullAccess else {
            throw EventError.noReminderAccess
        }
        
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = title
        reminder.calendar = eventStore.defaultCalendarForNewReminders() ?? eventStore.calendars(for: .reminder).first
        guard reminder.calendar != nil else {
            throw EventError.noReminderCalendarAvailable
        }
        
        // 设置到期时间
        var components = Calendar.current.dateComponents([.year, .month, .day], from: dueDate)
        if !isAllDay {
            components.hour = Calendar.current.component(.hour, from: dueDate)
            components.minute = Calendar.current.component(.minute, from: dueDate)
        }
        reminder.dueDateComponents = components
        
        // B-33：同步写入 EK priority——此前只写缓存，EK 侧提醒无优先级；
        // 语义映射：本项目 EventPriority 9=最高，EKReminder 1=最高、9=最低、0=无
        reminder.priority = Self.ekPriority(from: priority)
        
        // 设置提醒闹钟：多级 offsets 优先，单级 minutes 兼容
        reminder.alarms = Self.makeAlarms(offsets: reminderOffsets, minutes: reminderMinutes)
        
        try eventStore.save(reminder, commit: true)
        
        // 保存到本地缓存
        if let context = cacheService.context {
            let cached = CachedEvent(
                eventID: reminder.calendarItemIdentifier,
                title: reminder.title ?? "",
                startDate: dueDate,
                endDate: dueDate,
                isAllDay: isAllDay,
                calendarID: "reminder",
                calendarTitle: "提醒",
                calendarColorHex: reminder.calendar?.cgColor?.hexString ?? "#FF9500",
                category: .user,
                isReminder: true,
                isCompleted: false,
                priority: priority?.rawValue ?? 0,
                reminderMinutes: reminderMinutes ?? 0,
                eventColorHex: color?.rawValue
            )
            // 多级提醒：经 setter 写入以维护硬不变量 reminderMinutes == offsets.max()
            if let offsets = reminderOffsets, !offsets.isEmpty {
                cached.reminderOffsets = offsets
            }
            context.insert(cached)
            do {
                try context.save()
            } catch {
                AppLogger.sync.error("缓存同步失败: \(String(describing: error))")
            }
        }
    }
    
    /// 创建带组信息的系统日历事件（用于周期任务）
    @MainActor
    private func createCalendarEventWithGroupInfo(
        title: String,
        startDate: Date,
        endDate: Date?,
        isAllDay: Bool,
        calendar: EKCalendar?,
        priority: EventPriority? = nil,
        reminderMinutes: Int? = nil,
        reminderOffsets: [Int]? = nil,
        category: EventCategory,
        groupId: String,
        groupIndex: Int,
        recurrenceType: RecurrenceType,
        isLunar: Bool,
        color: EventColor? = nil
    ) throws {
        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = startDate
        // 全天事件的结束日期必须是第二天，否则EventKit会报错
        if isAllDay {
            event.endDate = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: startDate)) ?? startDate.addingTimeInterval(86400)
        } else {
            let calculatedEndDate = endDate ?? startDate.addingTimeInterval(3600)
            // 确保 endDate > startDate
            if calculatedEndDate <= startDate {
                event.endDate = startDate.addingTimeInterval(3600)
            } else {
                event.endDate = calculatedEndDate
            }
        }
        event.isAllDay = isAllDay
        let targetCalendar = calendar ?? eventStore.defaultCalendarForNewEvents ?? calendars.first
        event.calendar = targetCalendar

        // 设置提醒（仅当用户指定时才添加）：多级 offsets 优先，单级 minutes 兼容
        event.alarms = Self.makeAlarms(offsets: reminderOffsets, minutes: reminderMinutes)

        guard event.calendar != nil else {
            throw EventError.noCalendarAvailable
        }

        // B-5：与 createCalendarEvent 一致，用户分类事件统一打来源标记，
        // 避免清缓存重同步后被误归为 .system 而遭连带删除
        if category == .user {
            event.notes = "此事项来自SwallowCalendar应用"
        }

        try eventStore.save(event, span: .thisEvent)

        // 保存到本地缓存（带组信息）
        if let context = cacheService.context {
            let cached = CachedEvent(
                eventID: event.eventIdentifier,
                title: event.title ?? "",
                startDate: event.startDate,
                endDate: event.endDate,
                isAllDay: event.isAllDay,
                calendarID: event.calendar.calendarIdentifier,
                calendarTitle: event.calendar.title,
                calendarColorHex: event.calendar.cgColor?.hexString ?? "#007AFF",
                category: category,
                priority: priority?.rawValue ?? 0,
                groupId: groupId,
                groupIndex: groupIndex,
                recurrenceType: recurrenceType,
                isLunar: isLunar,
                reminderMinutes: reminderMinutes ?? 0,
                eventColorHex: color?.rawValue
            )
            // 多级提醒：经 setter 写入以维护硬不变量 reminderMinutes == offsets.max()
            if let offsets = reminderOffsets, !offsets.isEmpty {
                cached.reminderOffsets = offsets
            }
            context.insert(cached)
            do {
                try context.save()
            } catch {
                AppLogger.sync.error("缓存同步失败: \(String(describing: error))")
            }
        }
    }
    
    /// 创建带组信息的系统提醒（用于周期任务）
    @MainActor
    private func createReminderWithGroupInfo(
        title: String,
        dueDate: Date,
        isAllDay: Bool,
        priority: EventPriority? = nil,
        groupId: String,
        groupIndex: Int,
        recurrenceType: RecurrenceType,
        isLunar: Bool,
        reminderMinutes: Int? = nil,
        reminderOffsets: [Int]? = nil,
        color: EventColor? = nil
    ) throws {
        guard reminderAuthorizationStatus == .fullAccess else {
            throw EventError.noReminderAccess
        }
        
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = title
        reminder.calendar = eventStore.defaultCalendarForNewReminders() ?? eventStore.calendars(for: .reminder).first
        guard reminder.calendar != nil else {
            throw EventError.noReminderCalendarAvailable
        }
        
        // 设置到期时间
        var components = Calendar.current.dateComponents([.year, .month, .day], from: dueDate)
        if !isAllDay {
            components.hour = Calendar.current.component(.hour, from: dueDate)
            components.minute = Calendar.current.component(.minute, from: dueDate)
        }
        reminder.dueDateComponents = components
        
        // 设置提醒闹钟：多级 offsets 优先，单级 minutes 兼容
        reminder.alarms = Self.makeAlarms(offsets: reminderOffsets, minutes: reminderMinutes)
        
        try eventStore.save(reminder, commit: true)
        
        // 保存到本地缓存（带组信息）
        if let context = cacheService.context {
            let cached = CachedEvent(
                eventID: reminder.calendarItemIdentifier,
                title: reminder.title ?? "",
                startDate: dueDate,
                endDate: dueDate,
                isAllDay: isAllDay,
                calendarID: "reminder",
                calendarTitle: "提醒",
                calendarColorHex: reminder.calendar?.cgColor?.hexString ?? "#FF9500",
                category: .user,
                isReminder: true,
                isCompleted: false,
                priority: priority?.rawValue ?? 0,
                groupId: groupId,
                groupIndex: groupIndex,
                recurrenceType: recurrenceType,
                isLunar: isLunar,
                reminderMinutes: reminderMinutes ?? 0,
                eventColorHex: color?.rawValue
            )
            // 多级提醒：经 setter 写入以维护硬不变量 reminderMinutes == offsets.max()
            if let offsets = reminderOffsets, !offsets.isEmpty {
                cached.reminderOffsets = offsets
            }
            context.insert(cached)
            do {
                try context.save()
            } catch {
                AppLogger.sync.error("缓存同步失败: \(String(describing: error))")
            }
        }
    }

    /// 删除事件（日历事件或提醒）
    @MainActor
    func deleteEvent(eventID: String, isReminder: Bool = false) throws {
        // B-7：EK 对象缺失（已被外部删除等）不再直接 return——仍继续删除缓存，
        // 避免幽灵条目；对象存在才走 EK 删除
        if isReminder {
            if let reminder = eventStore.calendarItem(withIdentifier: eventID) as? EKReminder {
                try eventStore.remove(reminder, commit: true)
            } else {
                AppLogger.sync.warning("deleteEvent EKReminder NOT-FOUND，仅删缓存 id=\(eventID)")
            }
        } else {
            if let event = eventStore.event(withIdentifier: eventID) {
                try eventStore.remove(event, span: .thisEvent)
            } else {
                AppLogger.sync.warning("deleteEvent EKEvent NOT-FOUND，仅删缓存 id=\(eventID)")
            }
        }
        
        // 从本地缓存删除
        if let cached = findCachedEvent(eventID: eventID) {
            cacheService.context?.delete(cached)
            do {
                try cacheService.context?.save()
            } catch {
                // B-7：缓存删除失败必须记日志，空 catch 静默吞错无法排查
                AppLogger.sync.error("deleteEvent 缓存删除失败: \(String(describing: error))")
            }
        }
    }
    
    /// 确保 EKEvent 的 notes 中带有完成标记（自愈历史已办）
    /// - Note: 历史已办（[SC_COMPLETED] 机制引入前标记完成）的系统日历事件 notes 中没有标记，
    ///         同步时若缓存已完成而 EK 无标记，调用此方法补写标记，让系统日历成为完成状态的真源，
    ///         此后清缓存/换设备重新同步也能从系统日历恢复完成状态。
    /// - Returns: 是否补写成功（事件不存在或保存失败返回 false，但缓存已完成状态不受影响；
    ///            失败已在本方法内打日志，当前唯一调用方（同步自愈补写）仅关心副作用无需检查，
    ///            故标记 @discardableResult 消除未使用返回值警告，保留未来调用方检查能力）
    @MainActor
    @discardableResult
    func ensureCompletedMarker(for eventID: String) -> Bool {
        let completedMarker = "[SC_COMPLETED]"
        guard let event = eventStore.event(withIdentifier: eventID) else {
            AppLogger.sync.warning("ensureCompletedMarker EKEvent NOT-FOUND id=\(eventID)")
            return false
        }
        // 已有标记则无需补写
        if let notes = event.notes, notes.contains(completedMarker) {
            return true
        }
        if let notes = event.notes {
            event.notes = notes + " " + completedMarker
        } else {
            event.notes = completedMarker
        }
        do {
            try eventStore.save(event, span: .thisEvent)
            AppLogger.sync.info("ensureCompletedMarker 补写完成标记 id=\(eventID)")
            return true
        } catch {
            AppLogger.sync.error("ensureCompletedMarker 补写失败 id=\(eventID) err=\(String(describing: error))")
            return false
        }
    }

    /// 标记事件完成/未完成
    /// - Note: 对于系统提醒，会同步更新到系统提醒应用
    /// - Note: 对于系统日历事件，在 EKEvent 的 notes 中追加完成标记以持久化状态；
    ///         同步时会恢复 notes 中标记为已完成的事件状态
    /// - Note: 如果是周期任务，完成时会自动追加新的实例
    @MainActor
    func toggleEventCompleted(eventID: String, isCompleted: Bool, isReminder: Bool = false) async {
        // 幂等守卫：目标状态与缓存一致时跳过全部写入。防止“弹窗单条完成 + 全部完成”
        // 双重完成路径对同一周期事项重复追加实例（审查 P1：完成分支缺少状态检查）
        if let cached = findCachedEvent(eventID: eventID), cached.isCompleted == isCompleted {
            AppLogger.sync.debug("完成状态未变化，跳过写入 id=\(eventID) completed=\(isCompleted)")
            return
        }

        // B-2：跟踪 EK 写入是否失败（对象不存在不算失败——无旧状态可翻转）
        var ekSaveFailed = false

        if isReminder {
            // 使用 if let 而非 guard，确保即使 EventKit 中找不到该提醒，
            // 本地缓存仍能正常更新（已完成提醒可能无法通过 calendarItem 获取）
            if let reminder = eventStore.calendarItem(withIdentifier: eventID) as? EKReminder {
                reminder.isCompleted = isCompleted
                do {
                    try eventStore.save(reminder, commit: true)
                    AppLogger.sync.debug("EKReminder save ok id=\(eventID) completed=\(isCompleted)")
                } catch {
                    ekSaveFailed = true
                    AppLogger.sync.error("EKReminder save FAILED id=\(eventID) completed=\(isCompleted) err=\(String(describing: error))")
                }
            } else {
                AppLogger.sync.warning("EKReminder calendarItem NOT-FOUND 尝试兜底查询 id=\(eventID) completed=\(isCompleted)")
                // 兜底：calendarItem 对已完成的 iCloud 提醒可能返回 nil，
                // 此时若只更新缓存，重启后 syncReminders 会从 EK 拉到旧的未完成状态，
                // 导致已完成事项再次弹窗。改用全量查询找到后补写 EK，保证两端一致。
                if let reminder = await fetchReminderObject(byID: eventID) {
                    reminder.isCompleted = isCompleted
                    do {
                        try eventStore.save(reminder, commit: true)
                        AppLogger.sync.info("EKReminder save ok(fallback) id=\(eventID) completed=\(isCompleted)")
                    } catch {
                        ekSaveFailed = true
                        AppLogger.sync.error("EKReminder save FAILED(fallback) id=\(eventID) err=\(String(describing: error))")
                    }
                } else {
                    // 兜底仍未找到：事项多半已从 EventKit 删除，syncReminders 会同步删除缓存记录
                    AppLogger.sync.warning("EKReminder fallback NOT-FOUND 事项可能已删除 id=\(eventID)")
                }
            }
        } else {
            // 日历事件：在 EKEvent 的 notes 中追加完成标记，确保同步后能恢复完成状态
            if let event = eventStore.event(withIdentifier: eventID) {
                let completedMarker = "[SC_COMPLETED]"
                if isCompleted {
                    // 追加完成标记（避免重复添加）
                    if let notes = event.notes, !notes.contains(completedMarker) {
                        event.notes = notes + " " + completedMarker
                    } else if event.notes == nil {
                        event.notes = completedMarker
                    }
                } else {
                    // 移除完成标记
                    if let notes = event.notes {
                        event.notes = notes.replacingOccurrences(of: " " + completedMarker, with: "")
                            .replacingOccurrences(of: completedMarker, with: "")
                    }
                }
                do {
                    try eventStore.save(event, span: .thisEvent)
                    AppLogger.sync.debug("EKEvent save ok id=\(eventID) completed=\(isCompleted)")
                } catch {
                    ekSaveFailed = true
                    AppLogger.sync.error("EKEvent save FAILED id=\(eventID) completed=\(isCompleted) err=\(String(describing: error))")
                }
            } else {
                AppLogger.sync.warning("EKEvent NOT-FOUND EventKit未收到完成状态 id=\(eventID) completed=\(isCompleted)")
            }
        }
        
        // B-2：EK 保存失败时终止——不更新缓存完成状态、不追加周期实例，
        // 避免下次同步从 EK 拉回旧状态导致完成状态翻转、周期实例膨胀
        if ekSaveFailed {
            AppLogger.sync.warning("EK写入失败，已跳过缓存更新与周期追加 id=\(eventID) completed=\(isCompleted)")
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "同步失败"
            alert.informativeText = "完成状态写入系统日历/提醒失败，本次修改未生效，请稍后重试。"
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        // 更新本地缓存
        if let cached = findCachedEvent(eventID: eventID) {
            cached.isCompleted = isCompleted
            do {
                try cacheService.context?.save()
            } catch {
                AppLogger.sync.error("更新缓存失败: \(String(describing: error))")
            }
            
            // 如果是完成操作且是周期任务，追加新实例
            if isCompleted && cached.groupId != nil && cached.recurrenceType != .none {
                appendNextRecurringInstance(completedEventID: eventID)
            }
        }
    }

    /// 更新事件（日历事件或提醒）
    /// - Parameter reminderOffsets: 多级提醒偏移数组；nil = 不改提醒，空数组 = 清除全部提醒
    @MainActor
    func updateEvent(eventID: String, title: String?, startDate: Date?, endDate: Date?, isAllDay: Bool? = nil, isReminder: Bool = false, priority: EventPriority? = nil, reminderMinutes: Int? = nil, reminderOffsets: [Int]? = nil, color: EventColor? = nil) throws {
        if isReminder {
            guard let reminder = eventStore.calendarItem(withIdentifier: eventID) as? EKReminder else { return }
            if let title { reminder.title = title }
            // B-6：startDate 与 endDate 任一传入都更新到期时间（提醒只有 dueDate
            // 一个时间语义），原实现忽略 endDate 导致只调结束时间不生效
            if let dueSource = startDate ?? endDate {
                var components = Calendar.current.dateComponents([.year, .month, .day], from: dueSource)
                // 全天事件只写日期；非全天写入具体时间（isAllDay 未传时按原始时间
                // 是否带时分秒推断——B-22：原 <86400 判定会把跨天定时提醒
                //（如今天10:00~明天10:30，间隔>24h）误判为全天）
                let isTimed: Bool
                if let isAllDay {
                    isTimed = !isAllDay
                } else {
                    let comps = Calendar.current.dateComponents([.hour, .minute, .second], from: dueSource)
                    isTimed = (comps.hour ?? 0) != 0 || (comps.minute ?? 0) != 0 || (comps.second ?? 0) != 0
                }
                if isTimed {
                    components.hour = Calendar.current.component(.hour, from: dueSource)
                    components.minute = Calendar.current.component(.minute, from: dueSource)
                }
                reminder.dueDateComponents = components
            }
            // 更新提醒闹钟：多级 offsets 优先（空数组=清除），单级 minutes 兼容；
            // 两者均未传时不动 alarms（保持 nil = 不改提醒语义）
            if reminderOffsets != nil || reminderMinutes != nil {
                reminder.alarms = Self.makeAlarms(offsets: reminderOffsets, minutes: reminderMinutes)
            }
            try eventStore.save(reminder, commit: true)
        } else {
            guard let event = eventStore.event(withIdentifier: eventID) else { return }
            if let title { event.title = title }
            if let startDate { event.startDate = startDate }
            if let endDate { event.endDate = endDate }
            if let isAllDay { event.isAllDay = isAllDay }
            // E-6：切为全天时显式清 endDate——UI 全天保存传 endDate=nil，
            // 上面 if let 不执行会残留原截止时间；EK 全天单日惯例 endDate=startDate
            if let isAllDay, isAllDay {
                event.endDate = event.startDate
            }
            // 更新日历事件闹钟：多级 offsets 优先（空数组=清除），单级 minutes 兼容；
            // 两者均未传时不动 alarms（保持 nil = 不改提醒语义）
            if reminderOffsets != nil || reminderMinutes != nil {
                event.alarms = Self.makeAlarms(offsets: reminderOffsets, minutes: reminderMinutes)
            }
            try eventStore.save(event, span: .thisEvent)
        }

        // 更新本地缓存
        if let cached = findCachedEvent(eventID: eventID) {
            if let title { cached.title = title }
            if isReminder {
                // B-6：提醒只有到期时间一个语义，startDate==endDate 必须同步写，
                // 原实现只写 startDate、endDate 残留旧值导致缓存与 EK 分叉
                if let dueSource = startDate ?? endDate {
                    cached.startDate = dueSource
                    cached.endDate = dueSource
                }
            } else {
                if let startDate { cached.startDate = startDate }
                // E-6：切为全天时缓存 endDate 同步清为 startDate（零长全天单日），
                // 消除带时间→全天切换后的残留截止时间
                if let isAllDay, isAllDay {
                    cached.endDate = startDate ?? cached.startDate
                } else if let endDate {
                    cached.endDate = endDate
                }
            }
            // isAllDay 必须同步，否则"全天 ↔ 带时间"切换后缓存与 EK 不一致，UI 显示错误
            if let isAllDay { cached.isAllDay = isAllDay }
            if let priority { cached.priority = priority.rawValue }
            if let reminderOffsets {
                // 多级：经 setter 写入维护硬不变量（空数组=清除多级回退单级）
                cached.reminderOffsets = reminderOffsets
                if reminderOffsets.isEmpty {
                    // 清除提醒时单级归零，避免 includeExpired 分支按旧 max 误判"已设置提醒"
                    cached.reminderMinutes = 0
                }
            } else if let reminderMinutes {
                // G1：多级 JSON 可能已存在，直赋必须经显式方法反向重写最高档
                //（@Model 宏不保留 didSet，联动已显式化）
                cached.setReminderMinutesRewritingMax(reminderMinutes)
            }
            if let color { cached.eventColorHex = color.rawValue }
            cached.lastUpdated = Date()
            do {
                try cacheService.context?.save()
            } catch {
                // B-6：缓存保存失败记日志，try? 静默吞错无法排查
                AppLogger.sync.error("updateEvent 缓存保存失败: \(String(describing: error))")
            }
        }
    }
    
    /// 更新事件周期类型（用于将周期任务改为一次，或删除周期任务的未完成实例）
    @MainActor
    func updateEventRecurrence(eventID: String, newRecurrenceType: RecurrenceType) {
        guard let context = cacheService.context,
              let cached = findCachedEvent(eventID: eventID) else {
            return
        }
        
        let oldRecurrenceType = cached.recurrenceType
        let groupId = cached.groupId
        
        // 如果从周期改为一次，删除同组其他未完成事项
        if oldRecurrenceType != .none && newRecurrenceType == .none {
            if let groupId = groupId {
                deleteUncompletedInGroup(groupId: groupId)
            }
        }
        
        // 更新当前事件的周期类型
        cached.recurrenceType = newRecurrenceType
        if newRecurrenceType == .none {
            cached.groupId = nil
            cached.groupIndex = -1
        } else if oldRecurrenceType == .none {
            // E-2："1次→周期"补建组——生成 groupId 并将当前事件标记为首实例（groupIndex=0），
            // 与 createRecurringEvents 建组模式一致；否则完成后 appendNextRecurringInstance
            // 因缺 groupId 直接返回，无法生成次实例
            cached.groupId = UUID().uuidString
            cached.groupIndex = 0
        }
        
        do {
            try context.save()
        } catch {
        }
    }

    // MARK: - Sync

    /// 根据 eventID 查找缓存事件
    @MainActor
    private func findCachedEvent(eventID: String) -> CachedEvent? {
        guard let context = cacheService.context else { return nil }
        var descriptor = FetchDescriptor<CachedEvent>(predicate: #Predicate { $0.eventID == eventID })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// 手动同步日历事件到本地缓存
    func manualSync(preferences: [CalendarPreference], completion: ((Bool, String) -> Void)? = nil) {
        guard authorizationStatus == .fullAccess else {
            completion?(false, "日历权限不足，请在系统设置中授权")
            return
        }

        let enabledCals = enabledCalendars(preferences: preferences)
        guard !enabledCals.isEmpty else {
            // 没有开启的日历，直接返回成功
            DispatchQueue.main.async {
                completion?(true, "同步成功")
            }
            return
        }

        Task {
            // B-28：取真实同步结果回传——原实现无条件回"同步成功"，
            // 保存失败时 UI 无法感知，用户误以为数据已同步
            let success = await cacheService.syncEvents(from: self, calendars: enabledCals)
            await MainActor.run {
                completion?(success, success ? "同步成功" : "同步失败，请重试")
            }
        }
    }

    // MARK: - Helpers

    /// 生成周期任务的5个实例日期
    /// - Parameters:
    ///   - baseDate: 基准日期（第一个待办的日期）
    ///   - recurrenceType: 周期类型
    ///   - isLunar: 是否农历
    /// - Returns: 5个日期数组
    private func generateRecurringDates(baseDate: Date, recurrenceType: RecurrenceType, isLunar: Bool) -> [Date] {
        var dates: [Date] = [baseDate]
        
        for _ in 1..<5 {
            guard let lastDate = dates.last else { break }
            
            if isLunar {
                // 农历周期任务：需要特殊处理
                if let nextDate = getNextLunarDate(from: lastDate, recurrenceType: recurrenceType) {
                    dates.append(nextDate)
                } else {
                    break
                }
            } else {
                // 公历周期任务：直接计算
                if let nextDate = getNextGregorianDate(from: lastDate, recurrenceType: recurrenceType) {
                    dates.append(nextDate)
                } else {
                    break
                }
            }
        }
        
        return dates
    }
    
    /// 获取下一个公历日期
    private func getNextGregorianDate(from date: Date, recurrenceType: RecurrenceType) -> Date? {
        let calendar = Calendar.current
        
        switch recurrenceType {
        case .unlimited, .daily:
            return calendar.date(byAdding: .day, value: 1, to: date)
        case .weekly:
            return calendar.date(byAdding: .weekOfYear, value: 1, to: date)
        case .monthly:
            return calendar.date(byAdding: .month, value: 1, to: date)
        case .yearly:
            return calendar.date(byAdding: .year, value: 1, to: date)
        default:
            // B-18：.custom 无固定推进语义（B-32 复核：NLP 识别与 UI 选择器
            // 均不会产生 .custom，此分支实际不可达），返回 nil 中断序列兜底
            return nil
        }
    }
    
    /// 获取下一个农历日期
    /// - Note: 当前实现使用 Calendar(identifier: .chinese) 直接计算，对于农历闰月（如闰七月）的处理依赖于系统 Calendar 的实现。
    ///         在大多数情况下能正确工作，但在极端边界场景下可能需要额外验证。
    // internal 供测试 @testable 使用
    func getNextLunarDate(from date: Date, recurrenceType: RecurrenceType) -> Date? {
        let chineseCalendar = Calendar(identifier: .chinese)

        // B-17：改用 date(byAdding:) 由系统 Calendar 处理农历溢出——原组件加法
        // （month+1/day+30 后 date(from:)）在 29 天小月、无对应闰月时返回 nil，
        // 周期序列被截断；date(byAdding:) 对溢出做系统取整（如 30 日遇小月取月末），
        // 序列不再中断，闰月也按系统逐月推进语义处理
        switch recurrenceType {
        case .unlimited, .daily:
            return chineseCalendar.date(byAdding: .day, value: 1, to: date)
        case .weekly:
            return chineseCalendar.date(byAdding: .day, value: 7, to: date)
        case .monthly:
            return chineseCalendar.date(byAdding: .month, value: 1, to: date)
        case .yearly:
            return chineseCalendar.date(byAdding: .year, value: 1, to: date)
        default:
            return nil
        }
    }
    
    /// 查找周期任务组中未完成的实例数量
    @MainActor
    func countUncompletedInGroup(groupId: String) -> Int {
        guard let context = cacheService.context else { return 0 }
        
        let descriptor = FetchDescriptor<CachedEvent>(
            predicate: #Predicate<CachedEvent> { $0.groupId == groupId && !$0.isCompleted }
        )
        
        do {
            let events = try context.fetch(descriptor)
            return events.count
        } catch {
            AppLogger.sync.error("查询周期任务组失败: \(String(describing: error))")
            return 0
        }
    }
    
    /// 删除周期任务组中所有未完成的事件
    @MainActor
    func deleteUncompletedInGroup(groupId: String) {
        guard let context = cacheService.context else { return }
        
        let descriptor = FetchDescriptor<CachedEvent>(
            predicate: #Predicate<CachedEvent> { $0.groupId == groupId && !$0.isCompleted }
        )
        
        do {
            let events = try context.fetch(descriptor)
            for event in events {
                // 同步删除系统中的数据（提醒或日历事件），避免下次同步又恢复
                if event.isReminder {
                    if let reminder = eventStore.calendarItem(withIdentifier: event.eventID) as? EKReminder {
                        try? eventStore.remove(reminder, commit: true)
                    }
                } else {
                    if let ekEvent = eventStore.event(withIdentifier: event.eventID) {
                        try? eventStore.remove(ekEvent, span: .thisEvent)
                    }
                }
                context.delete(event)
            }
            try context.save()
        } catch {
            AppLogger.sync.error("删除周期任务组失败: \(String(describing: error))")
        }
    }
    
    /// 完成事件时追加新的周期任务实例
    @MainActor
    func appendNextRecurringInstance(completedEventID: String) {
        guard let context = cacheService.context else { return }
        
        // 查找已完成的事件
        guard let completedEvent = findCachedEvent(eventID: completedEventID),
              let groupId = completedEvent.groupId,
              completedEvent.recurrenceType != .none else {
            return
        }
        
        // 检查当前组内未完成数量
        let uncompletedCount = countUncompletedInGroup(groupId: groupId)
        
        // 如果少于5个，追加新的
        if uncompletedCount < 5 {
            // 找到最大的 groupIndex
            let descriptor = FetchDescriptor<CachedEvent>(
                predicate: #Predicate<CachedEvent> { $0.groupId == groupId }
            )
            
            do {
                let allEvents = try context.fetch(descriptor)
                guard let maxIndexEvent = allEvents.max(by: { $0.groupIndex < $1.groupIndex }) else { return }
                
                let nextIndex = maxIndexEvent.groupIndex + 1
                
                // 生成下一个日期
                guard let lastDate = maxIndexEvent.startDate else {
                    return
                }
                
                // 计算下一个日期
                var nextDate = completedEvent.isLunar
                    ? getNextLunarDate(from: lastDate, recurrenceType: completedEvent.recurrenceType)
                    : getNextGregorianDate(from: lastDate, recurrenceType: completedEvent.recurrenceType)
                
                // 如果生成的日期仍在过去，使用公共函数推进到下一个周期
                if let date = nextDate {
                    nextDate = CalendarService.advanceRecurrenceDate(date, recurrenceType: completedEvent.recurrenceType)
                }
                
                guard let finalDate = nextDate else {
                    return
                }
                
                // B-3：全天判定改用缓存 isAllDay 字段——原 hour/minute==0 判定
                // 会把 00:00 开始的定时事件误判为全天
                let isAllDay = completedEvent.isAllDay
                
                // 同步到系统日历/提醒（create 方法会同时插入缓存，避免重复插入）
                if completedEvent.isReminder {
                    // 创建系统提醒（带组信息）
                    try createReminderWithGroupInfo(
                        title: completedEvent.title,
                        dueDate: finalDate,
                        isAllDay: isAllDay,
                        priority: completedEvent.priority > 0 ? EventPriority(rawValue: completedEvent.priority) : nil,
                        groupId: groupId,
                        groupIndex: nextIndex,
                        recurrenceType: completedEvent.recurrenceType,
                        isLunar: completedEvent.isLunar,
                        // B-3：透传原事件闹钟提醒，避免后续实例丢失提醒
                        reminderMinutes: completedEvent.reminderMinutes,
                        color: completedEvent.eventColorHex.flatMap { EventColor(rawValue: $0) }
                    )
                } else {
                    // B-3：非全天实例沿用原事件时长（start/end 同步平移），原实现固定
                    // +1 小时导致用户原始时长（如 2 小时）丢失；日期缺失时兜底 +1 小时
                    let calendarEndDate: Date? = {
                        if isAllDay {
                            return Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: finalDate))
                        } else if let start = completedEvent.startDate, let end = completedEvent.endDate {
                            return finalDate.addingTimeInterval(end.timeIntervalSince(start))
                        } else {
                            return finalDate.addingTimeInterval(3600)
                        }
                    }()
                    
                    // 创建系统日历事件（带组信息）
                    try createCalendarEventWithGroupInfo(
                        title: completedEvent.title,
                        startDate: finalDate,
                        endDate: calendarEndDate,
                        isAllDay: isAllDay,
                        calendar: calendars.first { $0.calendarIdentifier == completedEvent.calendarID },
                        priority: completedEvent.priority > 0 ? EventPriority(rawValue: completedEvent.priority) : nil,
                        // B-3：透传原事件闹钟提醒（原显式 nil 导致后续实例无提醒）
                        reminderMinutes: completedEvent.reminderMinutes,
                        // B-23：沿用组内原始分类，原硬编码 .user 会把 system/system-subscribed 组实例误标为用户事件
                        category: completedEvent.category,
                        groupId: groupId,
                        groupIndex: nextIndex,
                        recurrenceType: completedEvent.recurrenceType,
                        isLunar: completedEvent.isLunar,
                        color: completedEvent.eventColorHex.flatMap { EventColor(rawValue: $0) }
                    )
                }
            } catch {
                AppLogger.sync.error("追加周期任务失败: \(String(describing: error))")
            }
        }
    }

    private func mapToCalendarEvent(_ ekEvent: EKEvent) -> CalendarEvent {
        // 系统日历同步的事件统一归为系统分类（不管日历类型是 calDAV 还是 subscription）
        let category: EventCategory = .system
        return CalendarEvent(
            id: ekEvent.eventIdentifier,
            title: ekEvent.title ?? "",
            startDate: ekEvent.startDate,
            endDate: ekEvent.endDate,
            isAllDay: ekEvent.isAllDay,
            calendarID: ekEvent.calendar.calendarIdentifier,
            calendarTitle: ekEvent.calendar.title,
            calendarColorHex: ekEvent.calendar.cgColor?.hexString ?? "#007AFF",
            category: category,
            isCompleted: false,
            priority: 0,  // 系统日历事件没有优先级
            isReminder: false,
            groupId: nil,
            recurrenceType: .none,
            reminderMinutes: Self.extractReminderMinutes(from: ekEvent.alarms),
            reminderOffsets: Self.extractReminderOffsets(from: ekEvent.alarms),
            eventColorHex: nil,
            notes: ekEvent.notes
        )
    }

    private func cachedToCalendarEvent(_ cached: CachedEvent) -> CalendarEvent {
        return CalendarEvent(
            id: cached.eventID,
            title: cached.title,
            startDate: cached.startDate,
            endDate: cached.endDate,
            isAllDay: cached.isAllDay,
            calendarID: cached.calendarID,
            calendarTitle: cached.calendarTitle,
            calendarColorHex: cached.calendarColorHex,
            category: cached.category,
            isCompleted: cached.isCompleted,
            priority: cached.priority,
            isReminder: cached.isReminder,
            groupId: cached.groupId,
            recurrenceType: cached.recurrenceType,
            reminderMinutes: cached.reminderMinutes,
            eventColorHex: cached.eventColorHex
        )
    }
    
    private func dayRange(for date: Date) -> (start: Date, end: Date) {
        let cal = Calendar.current
        let start = cal.startOfDay(for: date)
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        return (start, end)
    }
}

// MARK: - Event Error

enum EventError: LocalizedError {
    case noCalendarAvailable
    case noReminderAccess
    case noReminderCalendarAvailable

    var errorDescription: String? {
        switch self {
        case .noCalendarAvailable:
            return "没有可用的日历，请先在系统日历中创建一个日历账户"
        case .noReminderAccess:
            return "没有提醒权限，请在系统设置中授权访问提醒"
        case .noReminderCalendarAvailable:
            return "没有可用的提醒列表，请先在系统提醒中创建一个列表"
        }
    }
}

// MARK: - CGColor Extension

extension CGColor {
    var hexString: String {
        guard let components = components, components.count >= 3 else { return "#007AFF" }
        let r = Int(components[0] * 255)
        let g = Int(components[1] * 255)
        let b = Int(components[2] * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

// MARK: - Recurrence Helper

extension CalendarService {
    /// 将日期推进到下一个周期，确保结果 > 当前时间
    /// - Parameters:
    ///   - date: 原始日期
    ///   - recurrenceType: 周期类型
    /// - Returns: 推进后的日期（保证 > Date()）
    static func advanceRecurrenceDate(_ date: Date, recurrenceType: RecurrenceType) -> Date {
        let now = Date()

        // 如果日期已经在未来，直接返回
        guard date <= now else { return date }

        var currentDate = date

        // B-16：迭代护栏——多年前的一次性 daily 日期原会逐日 while 推进上千次，
        // 超限（约 10 年）直接返回当前时间兜底
        let maxIterations = 3660
        var iterations = 0
        // B-16：monthly 锚定日——date(byAdding: .month) 遇 31 日→小月会截断到月末，
        // 连续推进后锚点漂移（1/31→2/28→3/28），改按锚定日逐月构造
        let anchorDay = Calendar.current.component(.day, from: date)

        // 循环推进直到时间在未来
        while currentDate <= now {
            if iterations >= maxIterations {
                return now
            }
            iterations += 1
            switch recurrenceType {
            case .unlimited, .daily:
                currentDate = Calendar.current.date(byAdding: .day, value: 1, to: currentDate) ?? currentDate
            case .weekly:
                currentDate = Calendar.current.date(byAdding: .weekOfYear, value: 1, to: currentDate) ?? currentDate
            case .monthly:
                currentDate = nextAnchoredMonthlyDate(from: currentDate, anchorDay: anchorDay) ?? currentDate
            case .yearly:
                currentDate = Calendar.current.date(byAdding: .year, value: 1, to: currentDate) ?? currentDate
            case .none, .custom:
                // B-32：无推进语义，直接返回避免 while 死循环（date <= now 时循环条件恒真）
                return currentDate
            }
        }

        return currentDate
    }

    /// B-16：按锚定日推进到下一月的对应日期（锚定日超出该月天数时取月末）
    private static func nextAnchoredMonthlyDate(from date: Date, anchorDay: Int) -> Date? {
        let calendar = Calendar.current
        var comps = calendar.dateComponents([.year, .month], from: date)
        // 先落到当月 1 日：Calendar.date(from:) 对溢出 day 会滚动到下月（如 2 月 day=31
        // 产出 3 月 3 日且 non-nil），不能直接设 day=anchorDay
        comps.day = 1
        guard let first = calendar.date(from: comps),
              // 推进到下一月 1 日：本函数职责是"推进到下一月"，缺这步会返回同月锚定日，
              // advanceRecurrenceDate 的 while 循环输入输出恒等 → 死循环耗尽护栏
              let nextFirst = calendar.date(byAdding: .month, value: 1, to: first),
              let daysInMonth = calendar.range(of: .day, in: .month, for: nextFirst)?.count else {
            return nil
        }
        // 锚定日超出目标月天数（如 31 日遇 2 月）→ clamp 到该月最后一天
        var nextComps = calendar.dateComponents([.year, .month], from: nextFirst)
        nextComps.day = min(anchorDay, daysInMonth)
        // 保留原时间的时分秒：与原 date(byAdding: .month) 语义一致，否则重复事项时间归零
        nextComps.hour = calendar.component(.hour, from: date)
        nextComps.minute = calendar.component(.minute, from: date)
        nextComps.second = calendar.component(.second, from: date)
        return calendar.date(from: nextComps)
    }
}
