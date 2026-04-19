//
//  EventReminderListView.swift
//  SwallowCalendar
//

import SwiftUI
import EventKit

struct EventReminderListView: View {
    let selectedDate: Date
    let calendarService: CalendarService
    let calendarPreferences: [CalendarPreference]
    let filterMode: EventFilterMode
    let onEditEvent: ((CalendarEvent) -> Void)?
    let onDeleteEvent: ((CalendarEvent) -> Void)?
    var refreshTrigger: Bool = false  // 放在最后

    @State private var isExpanded = true

    private var events: [CalendarEvent] {
        // 依赖 refreshTrigger 以触发重新计算
        _ = refreshTrigger
        guard calendarService.authorizationStatus == .fullAccess else { return [] }
        let enabledCals = calendarService.enabledCalendars(preferences: calendarPreferences)
        let range = filterMode.dateRange(from: selectedDate)
        // 优先从缓存获取全天事件
        let events = calendarService.fetchCachedAllDayEvents(
            from: range.start,
            to: range.end,
            calendars: enabledCals
        )
        // 只显示用户创建的事件
        return events.filter { $0.category == .user }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text("提醒")
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
                    Text("暂无提醒事项")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.leading, 16)
                } else {
                    ForEach(events) { event in
                        EventItemRow(
                            event: event,
                            onEdit: onEditEvent,
                            onDelete: onDeleteEvent
                        )
                    }
                }
            }
        }
    }
}
