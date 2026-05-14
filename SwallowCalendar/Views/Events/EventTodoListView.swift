//
//  EventTodoListView.swift
//  SwallowCalendar
//
//  待办事项列表：倒计时在前，提醒在后，只显示未完成
//

import SwiftUI

struct EventTodoListView: View {
    @Environment(AppSettings.self) private var appSettings
    let selectedDate: Date
    let calendarService: CalendarService
    let calendarPreferences: [CalendarPreference]
    let filterMode: EventFilterMode
    @Binding var isExpanded: Bool
    let onToggle: () -> Void
    let onEditEvent: ((CalendarEvent) -> Void)?
    let onCompleteEvent: ((CalendarEvent) -> Void)?
    let onDeleteEvent: ((CalendarEvent) -> Void)?
    @Binding var refreshTrigger: Bool

    @State private var cachedEvents: [CalendarEvent] = []
    @State private var displayLimit = 50

    private var displayedEvents: [CalendarEvent] {
        Array(cachedEvents.prefix(displayLimit))
    }

    private var hasMoreEvents: Bool {
        cachedEvents.count > displayLimit
    }

    private func refreshCachedEvents() {
        let enabledCals = calendarService.enabledCalendars(preferences: calendarPreferences)
        let range = filterMode.dateRange(from: selectedDate)

        var timedEvents: [CalendarEvent] = []
        var allDayEvents: [CalendarEvent] = []
        var noDateEvents: [CalendarEvent] = []

        let cached = calendarService.fetchCachedEvents(
            from: range.start,
            to: range.end,
            calendars: enabledCals,
            includeNoDateReminders: true
        )
        for event in cached {
            guard event.category == .user && !event.isCompleted else { continue }
            
            if event.startDate == nil {
                noDateEvents.append(event)
            } else if event.hasTime {
                timedEvents.append(event)
            } else {
                allDayEvents.append(event)
            }
        }

        var allEvents: [CalendarEvent] = timedEvents + allDayEvents
        
        let isAscending = appSettings.sortOrder == .ascending
        
        switch appSettings.sortMode {
        case .default:
            allEvents.sort {
                let date0 = $0.startDate ?? .distantPast
                let date1 = $1.startDate ?? .distantPast
                if date0 != date1 {
                    return isAscending ? date0 < date1 : date0 > date1
                }
                return isAscending ? $0.priority < $1.priority : $0.priority > $1.priority
            }
        case .createTime:
            allEvents.sort {
                let date0 = $0.startDate ?? .distantPast
                let date1 = $1.startDate ?? .distantPast
                return isAscending ? date0 < date1 : date0 > date1
            }
        case .deadline:
            allEvents.sort {
                let date0 = $0.endDate ?? $0.startDate ?? .distantPast
                let date1 = $1.endDate ?? $1.startDate ?? .distantPast
                return isAscending ? date0 < date1 : date0 > date1
            }
        case .priority:
            allEvents.sort {
                return isAscending ? $0.priority < $1.priority : $0.priority > $1.priority
            }
        case .title:
            allEvents.sort {
                return isAscending ? $0.title < $1.title : $0.title > $1.title
            }
        case .reminder:
            allEvents.sort {
                if isAscending {
                    return !$0.isReminder && $1.isReminder
                } else {
                    return $0.isReminder && !$1.isReminder
                }
            }
        }
        
        allEvents.append(contentsOf: noDateEvents)
        cachedEvents = allEvents
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                onToggle()
            } label: {
                HStack {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text("待办事项")
                        .font(.system(size: 12, weight: .semibold))
                    Text("(\(cachedEvents.count))")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                ScrollView {
                    if cachedEvents.isEmpty {
                        Text("暂无待办事项")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 16)
                    } else {
                        LazyVStack(spacing: 4) {
                            ForEach(displayedEvents) { event in
                                EventItemRow(
                                    event: event,
                                    onEdit: onEditEvent,
                                    onDelete: onDeleteEvent,
                                    onComplete: onCompleteEvent,
                                    isOverdue: event.startDate != nil && event.startDate! < Date()
                                )
                            }
                            if hasMoreEvents {
                                Button {
                                    displayLimit += 50
                                } label: {
                                    Text("加载更多 (\(cachedEvents.count - displayLimit) 项)")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 4)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.top, 6)
                .frame(maxHeight: .infinity)
            }
        }
        .onAppear {
            refreshCachedEvents()
        }
        .onChange(of: refreshTrigger) { _, _ in
            refreshCachedEvents()
        }
        .onChange(of: filterMode) { _, _ in
            refreshCachedEvents()
        }
    }
}
