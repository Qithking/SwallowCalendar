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
    var calendars: [EKCalendar] = []
    var isLoading = false
    
    /// 事件缓存服务
    let cacheService = EventCacheService.shared

    private init() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
    }

    // MARK: - Authorization

    @MainActor
    func requestAccess() async -> Bool {
        do {
            let granted = try await eventStore.requestFullAccessToEvents()
            authorizationStatus = granted ? .fullAccess : .denied
            if granted {
                loadCalendars()
            }
            return granted
        } catch {
            authorizationStatus = .denied
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
            // 没有配置偏好，返回所有非订阅日历（用户日历）
            let userCalendars = calendars.filter { $0.type != .subscription }
            print("[CalendarService] enabledCalendars: no preferences, returning \(userCalendars.count) user calendars")
            return userCalendars
        }

        // 返回配置的日历 + 所有用户日历（确保用户创建的事件能显示）
        var result = calendars.filter { enabledIDs.contains($0.calendarIdentifier) }
        let userCalendars = calendars.filter { $0.type != .subscription && !enabledIDs.contains($0.calendarIdentifier) }
        result.append(contentsOf: userCalendars)

        print("[CalendarService] enabledCalendars: enabledIDs=\(enabledIDs), calendars count=\(calendars.count), result count=\(result.count)")
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
    func fetchCachedEvents(from startDate: Date, to endDate: Date, calendars: [EKCalendar]? = nil) -> [CalendarEvent] {
        let cached = cacheService.getEvents(from: startDate, to: endDate, calendars: calendars)
        return cached.map { cachedToCalendarEvent($0) }
    }

    /// 获取某天的事件
    func fetchEvents(for date: Date, calendars: [EKCalendar]? = nil) -> [CalendarEvent] {
        let (start, end) = dayRange(for: date)
        return fetchEvents(from: start, to: end, calendars: calendars)
    }
    
    /// 从缓存获取某天的事件（优先使用缓存）
    func fetchCachedEvents(for date: Date, calendars: [EKCalendar]? = nil) -> [CalendarEvent] {
        let cached = cacheService.getEvents(for: date, calendars: calendars)
        return cached.map { cachedToCalendarEvent($0) }
    }

    /// 获取未来的待办事件（有明确时间的）
    func fetchUpcomingTimedEvents(calendars: [EKCalendar]? = nil) -> [CalendarEvent] {
        let now = Date()
        let end = Calendar.current.date(byAdding: .year, value: 2, to: now)!
        var events = fetchEvents(from: now, to: end, calendars: calendars)
        print("[CalendarService] fetchUpcomingTimedEvents: raw events count=\(events.count)")
        print("[CalendarService] now=\(now), end=\(end)")

        // 调试：检查前几个事件
        for (i, event) in events.prefix(5).enumerated() {
            print("[CalendarService] event[\(i)]: title=\(event.title), isAllDay=\(event.isAllDay), hasTime=\(event.hasTime), startDate=\(String(describing: event.startDate))")
        }

        events = events.filter { $0.hasTime && $0.startDate ?? Date.distantPast > now }
        print("[CalendarService] fetchUpcomingTimedEvents: filtered events count=\(events.count)")
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
    func fetchCachedAllDayEvents(from startDate: Date, to endDate: Date, calendars: [EKCalendar]? = nil) -> [CalendarEvent] {
        var events = fetchCachedEvents(from: startDate, to: endDate, calendars: calendars)
        events = events.filter(\.isAllDay)
        events.sort { $0.startDate ?? .distantFuture < $1.startDate ?? .distantFuture }
        return events
    }

    // MARK: - CRUD

    /// 创建日历事件
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
        category: EventCategory = .system
    ) throws {
        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = startDate
        event.endDate = endDate ?? startDate.addingTimeInterval(3600)
        event.isAllDay = isAllDay
        let targetCalendar = calendar ?? eventStore.defaultCalendarForNewEvents ?? calendars.first
        event.calendar = targetCalendar
        print("[CalendarService] createEvent: title=\(title), calendar=\(targetCalendar?.title ?? "nil"), calendarID=\(targetCalendar?.calendarIdentifier ?? "nil"), isAllDay=\(isAllDay), category=\(category)")

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
        // 如果 reminderMinutes 为 nil 或 <= 0，不添加提醒

        guard event.calendar != nil else {
            throw EventError.noCalendarAvailable
        }
        try eventStore.save(event, span: .thisEvent)
    }

    /// 删除日历事件
    @MainActor
    func deleteEvent(eventID: String) throws {
        guard let event = eventStore.event(withIdentifier: eventID) else { return }
        try eventStore.remove(event, span: .thisEvent)
    }
    
    /// 标记事件完成/未完成（仅影响缓存中的标记，不影响系统事件）
    func toggleEventCompleted(eventID: String, isCompleted: Bool) {
        guard let context = cacheService.context else { return }
        
        let descriptor = FetchDescriptor<CachedEvent>()
        if let events = try? context.fetch(descriptor),
           let cached = events.first(where: { $0.eventID == eventID }) {
            cached.isCompleted = isCompleted
            try? context.save()
        }
    }

    /// 更新日历事件
    @MainActor
    func updateEvent(eventID: String, title: String?, startDate: Date?, endDate: Date?) throws {
        guard let event = eventStore.event(withIdentifier: eventID) else { return }
        if let title { event.title = title }
        if let startDate { event.startDate = startDate }
        if let endDate { event.endDate = endDate }
        try eventStore.save(event, span: .thisEvent)
    }

    // MARK: - Sync

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
            priority: 0  // 系统日历事件没有优先级
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
            priority: cached.priority
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

    var errorDescription: String? {
        switch self {
        case .noCalendarAvailable:
            return "没有可用的日历，请先在系统日历中创建一个日历账户"
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
