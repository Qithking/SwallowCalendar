//
//  CalendarService.swift
//  SwallowCalendar
//

import EventKit
import SwiftUI
import SwiftData

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

    private init() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        reminderAuthorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
    }

    // MARK: - Authorization

    /// 请求日历和提醒权限（同时请求，只弹一次授权框）
    @MainActor
    func requestAccess() async -> Bool {
        do {
            // 同时请求日历和提醒权限
            async let eventsGranted = eventStore.requestFullAccessToEvents()
            async let remindersGranted = eventStore.requestFullAccessToReminders()
            
            let (eventResult, reminderResult) = try await (eventsGranted, remindersGranted)
            
            authorizationStatus = eventResult ? .fullAccess : .denied
            reminderAuthorizationStatus = reminderResult ? .fullAccess : .denied
            
            if eventResult {
                loadCalendars()
            }
            
            return eventResult
        } catch {
            authorizationStatus = .denied
            reminderAuthorizationStatus = .denied
            return false
        }
    }

    // MARK: - Calendars

    @MainActor
    func loadCalendars() {
        calendars = eventStore.calendars(for: .event)
    }

    /// 获取已启用的日历（根据用户偏好过滤）
    /// 优先返回用户配置的日历，如果配置为空则返回所有用户日历
    func enabledCalendars(preferences: [CalendarPreference]) -> [EKCalendar] {
        let enabledIDs = Set(preferences.filter(\.isEnabled).map(\.calendarID))

        if enabledIDs.isEmpty {
            return calendars.filter { $0.type != .subscription }
        }

        // 返回配置的日历 + 所有用户日历（确保用户创建的事件能显示）
        var result = calendars.filter { enabledIDs.contains($0.calendarIdentifier) }
        let userCalendars = calendars.filter { $0.type != .subscription && !enabledIDs.contains($0.calendarIdentifier) }
        result.append(contentsOf: userCalendars)

        return result
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
    func fetchCachedEvents(for date: Date, calendars: [EKCalendar]? = nil, includeNoDateReminders: Bool = false) -> [CalendarEvent] {
        let cached = cacheService.getEvents(for: date, calendars: calendars, includeNoDateReminders: includeNoDateReminders)
        return cached.map { cachedToCalendarEvent($0) }
    }

    /// 获取未来的待办事件（有明确时间的）
    func fetchUpcomingTimedEvents(calendars: [EKCalendar]? = nil) -> [CalendarEvent] {
        let now = Date()
        let end = Calendar.current.date(byAdding: .year, value: 2, to: now)!
        var events = fetchEvents(from: now, to: end, calendars: calendars)
        events = events.filter { $0.hasTime && $0.startDate ?? Date.distantPast > now }
        events.sort { $0.startDate ?? .distantFuture < $1.startDate ?? .distantFuture }
        return events
    }

    /// 获取全天事件（提醒）
    func fetchAllDayEvents(from startDate: Date, to endDate: Date, calendars: [EKCalendar]? = nil) -> [CalendarEvent] {
        var events = fetchEvents(from: startDate, to: endDate, calendars: calendars)
        events = events.filter(\.isAllDay)
        events.sort { $0.startDate ?? .distantFuture < $1.startDate ?? .distantFuture }
        return events
    }
    
    /// 从缓存获取全天事件
    /// - Note: 包含无到期时间的系统提醒（用于待办列表）
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
            calendarTitle: reminder.calendar?.title ?? "提醒",
            calendarColorHex: reminder.calendar?.cgColor?.hexString ?? "#FF9500",
            category: .user,
            isCompleted: reminder.isCompleted,
            priority: 0,
            isReminder: true
        )
    }

    // MARK: - CRUD

    /// 创建日历事件或提醒
    /// - Note: 如果 asReminder 为 true，则创建到系统提醒；否则创建到系统日历
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
        category: EventCategory = .system,
        asReminder: Bool = false
    ) throws {
        if asReminder {
            try createReminder(
                title: title,
                dueDate: startDate,
                isAllDay: isAllDay,
                priority: priority,
                recurrence: recurrence
            )
        } else {
            try createCalendarEvent(
                title: title,
                startDate: startDate,
                endDate: endDate,
                isAllDay: isAllDay,
                calendar: calendar,
                priority: priority,
                recurrence: recurrence,
                reminderMinutes: reminderMinutes,
                category: category
            )
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
        category: EventCategory = .system
    ) throws {
        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = startDate
        event.endDate = endDate ?? startDate.addingTimeInterval(3600)
        event.isAllDay = isAllDay
        let targetCalendar = calendar ?? eventStore.defaultCalendarForNewEvents ?? calendars.first
        event.calendar = targetCalendar

        // 设置重复规则
        if let recurrence = recurrence, recurrence != .none {
            let freq: EKRecurrenceFrequency
            switch recurrence {
            case .daily: freq = .daily
            case .weekly: freq = .weekly
            case .monthly: freq = .monthly
            case .yearly: freq = .yearly
            case .none, .custom: freq = .daily
            }
            let rule = EKRecurrenceRule(recurrenceWith: freq, interval: 1, end: nil)
            event.addRecurrenceRule(rule)
        }

        // 设置提醒（仅当用户指定时才添加）
        if let minutes = reminderMinutes, minutes > 0 {
            let alarm = EKAlarm(relativeOffset: TimeInterval(-minutes * 60))
            event.addAlarm(alarm)
        }

        guard event.calendar != nil else {
            throw EventError.noCalendarAvailable
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
                priority: priority?.rawValue ?? 0
            )
            context.insert(cached)
            try? context.save()
        }
    }
    
    /// 创建系统提醒
    @MainActor
    private func createReminder(
        title: String,
        dueDate: Date,
        isAllDay: Bool,
        priority: EventPriority? = nil,
        recurrence: RecurrenceType? = nil
    ) throws {
        guard reminderAuthorizationStatus == .fullAccess else {
            throw EventError.noReminderAccess
        }
        
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = title
        reminder.calendar = eventStore.defaultCalendarForNewReminders() ?? eventStore.calendars(for: .reminder).first
        
        // 设置到期时间
        var components = Calendar.current.dateComponents([.year, .month, .day], from: dueDate)
        if !isAllDay {
            components.hour = Calendar.current.component(.hour, from: dueDate)
            components.minute = Calendar.current.component(.minute, from: dueDate)
        }
        reminder.dueDateComponents = components
        
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
                isCompleted: false,
                priority: priority?.rawValue ?? 0
            )
            context.insert(cached)
            try? context.save()
        }
    }

    /// 删除事件（日历事件或提醒）
    @MainActor
    func deleteEvent(eventID: String, isReminder: Bool = false) throws {
        if isReminder {
            guard let reminder = eventStore.calendarItem(withIdentifier: eventID) as? EKReminder else { return }
            try eventStore.remove(reminder, commit: true)
        } else {
            guard let event = eventStore.event(withIdentifier: eventID) else { return }
            try eventStore.remove(event, span: .thisEvent)
        }
        
        // 从本地缓存删除
        if let cached = findCachedEvent(eventID: eventID) {
            cacheService.context?.delete(cached)
            try? cacheService.context?.save()
        }
    }
    
    /// 标记事件完成/未完成
    /// - Note: 对于系统提醒，会同步更新到系统；对于日历事件，仅更新本地缓存
    @MainActor
    func toggleEventCompleted(eventID: String, isCompleted: Bool, isReminder: Bool = false) {
        if isReminder {
            guard let reminder = eventStore.calendarItem(withIdentifier: eventID) as? EKReminder else { return }
            reminder.isCompleted = isCompleted
            try? eventStore.save(reminder, commit: true)
        }
        
        // 更新本地缓存
        if let cached = findCachedEvent(eventID: eventID) {
            cached.isCompleted = isCompleted
            try? cacheService.context?.save()
        }
    }

    /// 更新事件（日历事件或提醒）
    @MainActor
    func updateEvent(eventID: String, title: String?, startDate: Date?, endDate: Date?, isReminder: Bool = false) throws {
        if isReminder {
            guard let reminder = eventStore.calendarItem(withIdentifier: eventID) as? EKReminder else { return }
            if let title { reminder.title = title }
            if let startDate {
                var components = Calendar.current.dateComponents([.year, .month, .day], from: startDate)
                // 如果不是全天事件，添加时间
                if let end = endDate {
                    let interval = end.timeIntervalSince(startDate)
                    if interval < 86400 { // 小于一天，说明有具体时间
                        components.hour = Calendar.current.component(.hour, from: startDate)
                        components.minute = Calendar.current.component(.minute, from: startDate)
                    }
                }
                reminder.dueDateComponents = components
            }
            try eventStore.save(reminder, commit: true)
        } else {
            guard let event = eventStore.event(withIdentifier: eventID) else { return }
            if let title { event.title = title }
            if let startDate { event.startDate = startDate }
            if let endDate { event.endDate = endDate }
            try eventStore.save(event, span: .thisEvent)
        }
        
        // 更新本地缓存
        if let cached = findCachedEvent(eventID: eventID) {
            if let title { cached.title = title }
            if let startDate { cached.startDate = startDate }
            if let endDate { cached.endDate = endDate }
            cached.lastUpdated = Date()
            try? cacheService.context?.save()
        }
    }

    // MARK: - Sync

    /// 根据 eventID 查找缓存事件
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
        Task {
            await cacheService.syncEvents(from: self, calendars: enabledCals)
            await MainActor.run {
                completion?(true, "同步成功")
            }
        }
    }

    // MARK: - Helpers

    private func mapToCalendarEvent(_ ekEvent: EKEvent) -> CalendarEvent {
        let category: EventCategory = ekEvent.calendar.type == .subscription ? .subscription : .system
        return CalendarEvent(
            id: ekEvent.eventIdentifier,
            title: ekEvent.title ?? "",
            startDate: ekEvent.startDate,
            endDate: ekEvent.endDate,
            isAllDay: ekEvent.isAllDay,
            calendarTitle: ekEvent.calendar.title,
            calendarColorHex: ekEvent.calendar.cgColor?.hexString ?? "#007AFF",
            category: category,
            isCompleted: false,
            priority: 0,  // 系统日历事件没有优先级
            isReminder: false
        )
    }

    private func cachedToCalendarEvent(_ cached: CachedEvent) -> CalendarEvent {
        return CalendarEvent(
            id: cached.eventID,
            title: cached.title,
            startDate: cached.startDate,
            endDate: cached.endDate,
            isAllDay: cached.isAllDay,
            calendarTitle: cached.calendarTitle,
            calendarColorHex: cached.calendarColorHex,
            category: cached.category,
            isCompleted: cached.isCompleted,
            priority: cached.priority,
            isReminder: cached.calendarTitle == "提醒"
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
