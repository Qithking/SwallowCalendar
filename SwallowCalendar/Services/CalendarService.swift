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

    // MARK: - Public Methods

    /// 根据事件标识符获取 EKEvent
    func getEvent(withIdentifier identifier: String) -> EKEvent? {
        return eventStore.event(withIdentifier: identifier)
    }

    // MARK: - Authorization

    /// 请求日历和提醒权限（同时请求，只弹一次授权框）
    /// 返回 (日历授权成功, 提醒授权成功)
    @MainActor
    func requestAccess() async -> (calendar: Bool, reminder: Bool) {
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

            return (eventResult, reminderResult)
        } catch {
            authorizationStatus = .denied
            reminderAuthorizationStatus = .denied
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
            isReminder: true,
            groupId: nil,
            recurrenceType: .none
        )
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
        category: EventCategory = .system,
        asReminder: Bool = false,
        isLunar: Bool = false
    ) throws {
        let recurrenceType = recurrence ?? .none
        
        // 周期任务需要确保时间在当前时间之后
        var finalStartDate = startDate
        var finalEndDate = endDate
        if recurrenceType != .none && startDate <= Date() {
            // 周期任务：如果时间已过，推进到下一个周期
            finalStartDate = CalendarService.advanceRecurrenceDate(startDate, recurrenceType: recurrenceType)
            
            // 同时推进 endDate（如果有）
            if let ed = endDate {
                let timeDiff = ed.timeIntervalSince(startDate)
                finalEndDate = finalStartDate.addingTimeInterval(timeDiff)
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
                isLunar: isLunar
            )
        } else {
            // 非周期任务，创建一个（允许过去时间）
            if asReminder {
                try createReminder(
                    title: title,
                    dueDate: startDate,
                    isAllDay: isAllDay,
                    priority: priority,
                    recurrence: nil
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
                    category: category
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
        category: EventCategory,
        asReminder: Bool,
        isLunar: Bool
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
                    isLunar: isLunar
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
                    isLunar: isLunar
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
        category: EventCategory = .system
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
        
        // 如果是用户分类且开启了同步至系统日历，在备注中标记
        if category == .user && AppSettings.shared.syncEventsToSystem {
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
                priority: priority?.rawValue ?? 0
            )
            context.insert(cached)
            do {
                try context.save()
            } catch {
                // 缓存同步失败，记录到日志系统（待实现）
            }
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
            do {
                try context.save()
            } catch {
                // 缓存同步失败，记录到日志系统（待实现）
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
        category: EventCategory,
        groupId: String,
        groupIndex: Int,
        recurrenceType: RecurrenceType,
        isLunar: Bool
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

        // 设置提醒（仅当用户指定时才添加）
        if let minutes = reminderMinutes, minutes > 0 {
            let alarm = EKAlarm(relativeOffset: TimeInterval(-minutes * 60))
            event.addAlarm(alarm)
        }

        guard event.calendar != nil else {
            throw EventError.noCalendarAvailable
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
                isLunar: isLunar
            )
            context.insert(cached)
            do {
                try context.save()
            } catch {
                // 缓存同步失败，记录到日志系统（待实现）
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
        isLunar: Bool
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
                isCompleted: false,
                priority: priority?.rawValue ?? 0,
                groupId: groupId,
                groupIndex: groupIndex,
                recurrenceType: recurrenceType,
                isLunar: isLunar
            )
            context.insert(cached)
            do {
                try context.save()
            } catch {
                // 缓存同步失败，记录到日志系统（待实现）
            }
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
            do {
                try cacheService.context?.save()
            } catch {
                // 删除缓存失败，记录到日志系统（待实现）
            }
        }
    }
    
    /// 标记事件完成/未完成
    /// - Note: 对于系统提醒，会同步更新到系统；对于日历事件，仅更新本地缓存
    /// - Note: 如果是周期任务，完成时会自动追加新的实例
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
            do {
                try cacheService.context?.save()
            } catch {
                // 更新缓存失败，记录到日志系统（待实现）
            }
            
            // 如果是完成操作且是周期任务，追加新实例
            if isCompleted && cached.groupId != nil && cached.recurrenceType != .none {
                appendNextRecurringInstance(completedEventID: eventID)
            }
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
        }
        
        do {
            try context.save()
        } catch {
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
        guard !enabledCals.isEmpty else {
            // 没有开启的日历，直接返回成功
            DispatchQueue.main.async {
                completion?(true, "同步成功")
            }
            return
        }

        Task {
            await cacheService.syncEvents(from: self, calendars: enabledCals)
            await MainActor.run {
                completion?(true, "同步成功")
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
        case .daily:
            return calendar.date(byAdding: .day, value: 1, to: date)
        case .weekly:
            return calendar.date(byAdding: .weekOfYear, value: 1, to: date)
        case .monthly:
            return calendar.date(byAdding: .month, value: 1, to: date)
        case .yearly:
            return calendar.date(byAdding: .year, value: 1, to: date)
        default:
            return nil
        }
    }
    
    /// 获取下一个农历日期
    /// - Note: 当前实现使用 Calendar(identifier: .chinese) 直接计算，对于农历闰月（如闰七月）的处理依赖于系统 Calendar 的实现。
    ///         在大多数情况下能正确工作，但在极端边界场景下可能需要额外验证。
    private func getNextLunarDate(from date: Date, recurrenceType: RecurrenceType) -> Date? {
        let chineseCalendar = Calendar(identifier: .chinese)
        
        // 将公历日期转为农历
        var lunarComponents = chineseCalendar.dateComponents([.year, .month, .day], from: date)
        
        guard let lunarYear = lunarComponents.year,
              let lunarMonth = lunarComponents.month,
              let lunarDay = lunarComponents.day else {
            return nil
        }
        
        // 根据周期类型增加农历时间
        switch recurrenceType {
        case .daily:
            // 农历每天：加1天
            lunarComponents.day = lunarDay + 1
        case .weekly:
            // 农历每周：加7天
            lunarComponents.day = lunarDay + 7
        case .monthly:
            // 农历每月：加1个月
            lunarComponents.month = lunarMonth + 1
        case .yearly:
            // 农历每年：加1年
            lunarComponents.year = lunarYear + 1
        default:
            return nil
        }
        
        // 将农历组件转回公历日期
        return chineseCalendar.date(from: lunarComponents)
    }
    
    /// 查找周期任务组中未完成的实例数量
    func countUncompletedInGroup(groupId: String) -> Int {
        guard let context = cacheService.context else { return 0 }
        
        let descriptor = FetchDescriptor<CachedEvent>(
            predicate: #Predicate<CachedEvent> { $0.groupId == groupId && !$0.isCompleted }
        )
        
        do {
            let events = try context.fetch(descriptor)
            return events.count
        } catch {
            // 查询周期任务组失败，记录到日志系统（待实现）
            return 0
        }
    }
    
    /// 删除周期任务组中所有未完成的事件
    func deleteUncompletedInGroup(groupId: String) {
        guard let context = cacheService.context else { return }
        
        let descriptor = FetchDescriptor<CachedEvent>(
            predicate: #Predicate<CachedEvent> { $0.groupId == groupId && !$0.isCompleted }
        )
        
        do {
            let events = try context.fetch(descriptor)
            for event in events {
                // 如果是系统提醒，也删除系统提醒
                if event.calendarTitle == "提醒" {
                    if let reminder = eventStore.calendarItem(withIdentifier: event.eventID) as? EKReminder {
                        try? eventStore.remove(reminder, commit: true)
                    }
                }
                context.delete(event)
            }
            try context.save()
        } catch {
            // 删除周期任务组失败，记录到日志系统（待实现）
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
                
                // 创建新的事件
                let newEventID = UUID().uuidString
                let isAllDay = Calendar.current.component(.hour, from: lastDate) == 0
                    && Calendar.current.component(.minute, from: lastDate) == 0
                
                // 全天事件的结束日期是第二天
                let cachedEndDate: Date? = {
                    if isAllDay {
                        return Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: finalDate))
                    } else {
                        return finalDate.addingTimeInterval(3600)
                    }
                }()
                
                // 保存到本地缓存
                let cached = CachedEvent(
                    eventID: newEventID,
                    title: completedEvent.title,
                    startDate: finalDate,
                    endDate: cachedEndDate,
                    isAllDay: isAllDay,
                    calendarID: completedEvent.calendarID,
                    calendarTitle: completedEvent.calendarTitle,
                    calendarColorHex: completedEvent.calendarColorHex,
                    category: .user,
                    isCompleted: false,
                    priority: completedEvent.priority,
                    groupId: groupId,
                    groupIndex: nextIndex,
                    recurrenceType: completedEvent.recurrenceType,
                    isLunar: completedEvent.isLunar
                )
                context.insert(cached)
                try context.save()
                
                // 同步到系统日历/提醒
                if completedEvent.calendarTitle == "提醒" {
                    // 创建系统提醒
                    try createReminder(
                        title: completedEvent.title,
                        dueDate: finalDate,
                        isAllDay: isAllDay,
                        priority: completedEvent.priority > 0 ? EventPriority(rawValue: completedEvent.priority) : nil,
                        recurrence: nil  // 每个实例都是独立的
                    )
                } else {
                    // 全天事件的结束日期是第二天
                    let calendarEndDate: Date? = {
                        if isAllDay {
                            return Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: finalDate))
                        } else {
                            return finalDate.addingTimeInterval(3600)
                        }
                    }()
                    
                    // 创建系统日历事件
                    try createCalendarEvent(
                        title: completedEvent.title,
                        startDate: finalDate,
                        endDate: calendarEndDate,
                        isAllDay: isAllDay,
                        calendar: calendars.first { $0.calendarIdentifier == completedEvent.calendarID },
                        priority: completedEvent.priority > 0 ? EventPriority(rawValue: completedEvent.priority) : nil,
                        recurrence: nil,
                        reminderMinutes: nil,
                        category: .user
                    )
                }
            } catch {
                // 追加周期任务失败，记录到日志系统（待实现）
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
            calendarTitle: ekEvent.calendar.title,
            calendarColorHex: ekEvent.calendar.cgColor?.hexString ?? "#007AFF",
            category: category,
            isCompleted: false,
            priority: 0,  // 系统日历事件没有优先级
            isReminder: false,
            groupId: nil,
            recurrenceType: .none
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
            isReminder: cached.calendarTitle == "提醒",
            groupId: cached.groupId,
            recurrenceType: cached.recurrenceType
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
        
        // 循环推进直到时间在未来
        while currentDate <= now {
            switch recurrenceType {
            case .daily:
                currentDate = Calendar.current.date(byAdding: .day, value: 1, to: currentDate) ?? currentDate
            case .weekly:
                currentDate = Calendar.current.date(byAdding: .weekOfYear, value: 1, to: currentDate) ?? currentDate
            case .monthly:
                currentDate = Calendar.current.date(byAdding: .month, value: 1, to: currentDate) ?? currentDate
            case .yearly:
                currentDate = Calendar.current.date(byAdding: .year, value: 1, to: currentDate) ?? currentDate
            case .none, .custom:
                break
            }
        }
        
        return currentDate
    }
}
