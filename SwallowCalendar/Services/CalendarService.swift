//
//  CalendarService.swift
//  SwallowCalendar
//

import EventKit
import SwiftUI

@Observable
final class CalendarService {
    static let shared = CalendarService()

    private let eventStore = EKEventStore()
    var authorizationStatus: EKAuthorizationStatus = .notDetermined
    var calendars: [EKCalendar] = []
    var isLoading = false

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
    func enabledCalendars(preferences: [CalendarPreference]) -> [EKCalendar] {
        let enabledIDs = Set(preferences.filter(\.isEnabled).map(\.calendarID))
        return calendars.filter { enabledIDs.contains($0.calendarIdentifier) || enabledIDs.isEmpty }
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

    /// 获取某天的事件
    func fetchEvents(for date: Date, calendars: [EKCalendar]? = nil) -> [CalendarEvent] {
        let (start, end) = dayRange(for: date)
        return fetchEvents(from: start, to: end, calendars: calendars)
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
        reminderMinutes: Int? = nil
    ) throws {
        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = startDate
        event.endDate = endDate ?? startDate.addingTimeInterval(3600)
        event.isAllDay = isAllDay
        event.calendar = calendar ?? eventStore.defaultCalendarForNewEvents ?? calendars.first

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

        // 设置提醒
        if let minutes = reminderMinutes, minutes > 0 {
            let alarm = EKAlarm(relativeOffset: TimeInterval(-minutes * 60))
            event.addAlarm(alarm)
        } else {
            // 默认提前10分钟提醒
            let alarm = EKAlarm(relativeOffset: -600)
            event.addAlarm(alarm)
        }

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

    /// 更新日历事件
    @MainActor
    func updateEvent(eventID: String, title: String?, startDate: Date?, endDate: Date?) throws {
        guard let event = eventStore.event(withIdentifier: eventID) else { return }
        if let title { event.title = title }
        if let startDate { event.startDate = startDate }
        if let endDate { event.endDate = endDate }
        try eventStore.save(event, span: .thisEvent)
    }

    // MARK: - Helpers

    private func mapToCalendarEvent(_ ekEvent: EKEvent) -> CalendarEvent {
        let isSubscription = ekEvent.calendar.type == .subscription
        return CalendarEvent(
            id: ekEvent.eventIdentifier,
            title: ekEvent.title ?? "",
            startDate: ekEvent.startDate,
            endDate: ekEvent.endDate,
            isAllDay: ekEvent.isAllDay,
            calendarTitle: ekEvent.calendar.title,
            calendarColorHex: ekEvent.calendar.cgColor?.hexString ?? "#007AFF",
            source: .system,
            isSubscription: isSubscription
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
