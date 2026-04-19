//
//  EventTodoListView.swift
//  SwallowCalendar
//
//  合并的待办事项列表：倒计时在前，提醒在后，只显示未完成
//

import SwiftUI
import EventKit

struct EventTodoListView: View {
    let selectedDate: Date
    let calendarService: CalendarService
    let calendarPreferences: [CalendarPreference]
    let filterMode: EventFilterMode
    @Binding var isExpanded: Bool
    let onToggle: () -> Void
    let onEditEvent: ((CalendarEvent) -> Void)?
    let onCompleteEvent: ((CalendarEvent) -> Void)?
    let onDeleteEvent: ((CalendarEvent) -> Void)?
    var refreshTrigger: Bool = false

    private var events: [CalendarEvent] {
        _ = refreshTrigger
        guard calendarService.authorizationStatus == .fullAccess else { return [] }
        let enabledCals = calendarService.enabledCalendars(preferences: calendarPreferences)
        let range = filterMode.dateRange(from: selectedDate)
        
        // 获取所有事件
        var countdownEvents: [CalendarEvent] = []
        var allDayEvents: [CalendarEvent] = []
        
        // 倒计时事件
        let timedEvents = calendarService.fetchUpcomingTimedEvents(calendars: enabledCals)
        for event in timedEvents {
            guard let start = event.startDate, start >= range.start && start < range.end else { continue }
            // 排除订阅日历的事件（显示系统日历和用户日历）
            if !event.isSubscription && !event.isCompleted {
                countdownEvents.append(event)
            }
        }
        
        // 全天事件（提醒）
        let dayEvents = calendarService.fetchCachedAllDayEvents(
            from: range.start,
            to: range.end,
            calendars: enabledCals
        )
        for event in dayEvents {
            // 排除订阅日历的事件
            if !event.isSubscription && !event.isCompleted {
                allDayEvents.append(event)
            }
        }
        
        // 倒计时在前，提醒在后
        return countdownEvents + allDayEvents
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                onToggle()
            } label: {
                HStack {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text("待办事项")
                        .font(.system(size: 12, weight: .semibold))
                    Text("(\(events.count))")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                if events.isEmpty {
                    Text("暂无待办事项")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.leading, 16)
                } else {
                    ForEach(events) { event in
                        EventItemRow(
                            event: event,
                            onEdit: onEditEvent,
                            onDelete: onDeleteEvent,
                            onComplete: onCompleteEvent
                        )
                    }
                }
            }
        }
    }
}
