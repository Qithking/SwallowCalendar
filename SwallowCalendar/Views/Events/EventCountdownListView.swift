//
//  EventCountdownListView.swift
//  SwallowCalendar
//

import SwiftUI
import EventKit

struct EventCountdownListView: View {
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
        var events = calendarService.fetchUpcomingTimedEvents(calendars: enabledCals)

        // 应用过滤
        let range = filterMode.dateRange(from: selectedDate)
        events = events.filter { event in
            guard let start = event.startDate else { return false }
            return start >= range.start && start < range.end
        }

        // 只显示用户创建的事件
        return events.filter { $0.category == .user }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 标题行（可折叠）
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text("待办倒计时")
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
                            onDelete: onDeleteEvent
                        )
                    }
                }
            }
        }
    }
}
