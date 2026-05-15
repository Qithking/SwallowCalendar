//
//  EventCompletedListView.swift
//  SwallowCalendar
//
//  已办事项列表：显示所有已完成的用户事件
//

import SwiftUI
import EventKit
import SwiftData

struct EventCompletedListView: View {
    @Environment(AppSettings.self) private var appSettings
    let selectedDate: Date
    let calendarService: CalendarService
    let calendarPreferences: [CalendarPreference]
    let filterMode: EventFilterMode
    @Binding var isExpanded: Bool
    let onToggle: () -> Void
    let onEditEvent: ((CalendarEvent) -> Void)?
    let onUncompleteEvent: ((CalendarEvent) -> Void)?
    let onDeleteEvent: ((CalendarEvent) -> Void)?
    @Binding var refreshTrigger: Bool

    @State private var cachedEvents: [CalendarEvent] = []
    @State private var displayLimit = 50
    @State private var refreshTask: Task<Void, Never>?

    private var displayedEvents: [CalendarEvent] {
        Array(cachedEvents.prefix(displayLimit))
    }

    private var hasMoreEvents: Bool {
        cachedEvents.count > displayLimit
    }

    private func debouncedRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            refreshCachedEvents()
        }
    }

    private func refreshCachedEvents() {
        let enabledCals = calendarService.enabledCalendars(preferences: calendarPreferences)
        let range = filterMode.dateRange(from: selectedDate)

        let cached = calendarService.fetchCachedEvents(
            from: range.start,
            to: range.end,
            calendars: enabledCals,
            includeNoDateReminders: true
        )
        
        let result = cached.filter { event in
            event.category == .user &&
            event.isCompleted &&
            !event.title.trimmingCharacters(in: .whitespaces).isEmpty
        }

        var sorted = result
        let isAscending = appSettings.sortOrder == .ascending
        
        switch appSettings.sortMode {
        case .default:
            sorted.sort {
                if $0.priority != $1.priority {
                    return isAscending ? $0.priority < $1.priority : $0.priority > $1.priority
                }
                return isAscending ? ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) : ($0.startDate ?? .distantPast) > ($1.startDate ?? .distantPast)
            }
        case .createTime:
            sorted.sort {
                return isAscending ? ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) : ($0.startDate ?? .distantPast) > ($1.startDate ?? .distantPast)
            }
        case .deadline:
            sorted.sort {
                let date0 = $0.endDate ?? $0.startDate ?? .distantPast
                let date1 = $1.endDate ?? $1.startDate ?? .distantPast
                return isAscending ? date0 < date1 : date0 > date1
            }
        case .priority:
            sorted.sort {
                return isAscending ? $0.priority < $1.priority : $0.priority > $1.priority
            }
        case .title:
            sorted.sort {
                return isAscending ? $0.title < $1.title : $0.title > $1.title
            }
        case .reminder:
            sorted.sort {
                if isAscending {
                    return !$0.isReminder && $1.isReminder
                } else {
                    return $0.isReminder && !$1.isReminder
                }
            }
        }
        
        cachedEvents = sorted
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
                    Text("已办事项")
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
                        Text("暂无已办事项")
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
                                    onUncomplete: onUncompleteEvent
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
            debouncedRefresh()
        }
        .onChange(of: refreshTrigger) { _, _ in
            debouncedRefresh()
        }
        .onChange(of: filterMode) { _, _ in
            debouncedRefresh()
        }
    }
}
