//
//  EventCompletedListView.swift
//  SwallowCalendar
//
//  已办事项列表：显示所有已完成的用户事件
//

import SwiftUI
import EventKit

struct EventCompletedListView: View {
    let selectedDate: Date
    let calendarService: CalendarService
    let calendarPreferences: [CalendarPreference]
    let filterMode: EventFilterMode
    @Binding var isExpanded: Bool
    let onToggle: () -> Void
    let onEditEvent: ((CalendarEvent) -> Void)?
    let onUncompleteEvent: ((CalendarEvent) -> Void)?
    let onDeleteEvent: ((CalendarEvent) -> Void)?
    var refreshTrigger: Bool = false

    private var events: [CalendarEvent] {
        _ = refreshTrigger
        guard calendarService.authorizationStatus == .fullAccess else { return [] }
        let enabledCals = calendarService.enabledCalendars(preferences: calendarPreferences)
        let range = filterMode.dateRange(from: selectedDate)
        
        // 获取所有事件并筛选已完成的非订阅日历事件
        var result: [CalendarEvent] = []
        
        // 倒计时事件
        let timedEvents = calendarService.fetchUpcomingTimedEvents(calendars: enabledCals)
        for event in timedEvents {
            guard let start = event.startDate, start >= range.start && start < range.end else { continue }
            // 排除订阅日历的事件
            if !event.isSubscription && event.isCompleted {
                result.append(event)
            }
        }
        
        // 全天事件
        let dayEvents = calendarService.fetchCachedAllDayEvents(
            from: range.start,
            to: range.end,
            calendars: enabledCals
        )
        for event in dayEvents {
            // 排除订阅日历的事件
            if !event.isSubscription && event.isCompleted {
                result.append(event)
            }
        }
        
        return result
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
                    Text("已办事项")
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
                    Text("暂无已办事项")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.leading, 16)
                } else {
                    ForEach(events) { event in
                        EventItemRow(
                            event: event,
                            onEdit: onEditEvent,
                            onDelete: onDeleteEvent,
                            onUncomplete: onUncompleteEvent
                        )
                    }
                }
            }
        }
    }
}
