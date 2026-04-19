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
    @Binding var refreshTrigger: Bool

    private var events: [CalendarEvent] {
        _ = refreshTrigger
        let enabledCals = calendarService.enabledCalendars(preferences: calendarPreferences)
        let range = filterMode.dateRange(from: selectedDate)
        
        var result: [CalendarEvent] = []
        
        // 从缓存读取事件
        let cachedEvents = calendarService.fetchCachedEvents(
            from: range.start,
            to: range.end,
            calendars: enabledCals
        )
        for event in cachedEvents {
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
            if !event.isSubscription && event.isCompleted {
                result.append(event)
            }
        }
        
        // 排序：优先级降序，时间降序（只有 user 分类才有优先级）
        return result.sorted {
            if $0.category == .user && $1.category == .user {
                if $0.priority != $1.priority {
                    return $0.priority > $1.priority
                }
            } else if $0.category == .user {
                return true
            } else if $1.category == .user {
                return false
            }
            return ($0.startDate ?? .distantPast) > ($1.startDate ?? .distantPast)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 固定标题
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

            // 可滚动的内容区域
            if isExpanded {
                ScrollView {
                    if events.isEmpty {
                        Text("暂无已办事项")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 16)
                    } else {
                        LazyVStack(spacing: 4) {
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
                .padding(.top, 6)
                .frame(maxHeight: 200)
            }
        }
    }
}
