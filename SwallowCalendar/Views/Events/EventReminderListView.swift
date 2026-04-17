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

    @State private var isExpanded = true

    private var events: [CalendarEvent] {
        guard calendarService.authorizationStatus == .fullAccess else { return [] }
        let enabledCals = calendarService.enabledCalendars(preferences: calendarPreferences)
        let range = filterMode.dateRange(from: selectedDate)
        var events = calendarService.fetchAllDayEvents(
            from: range.start,
            to: range.end,
            calendars: enabledCals
        )
        return events
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
                        EventItemRow(event: event)
                    }
                }
            }
        }
    }
}
