//
//  EventTodoListView.swift
//  SwallowCalendar
//
//  待办事项列表：倒计时在前，提醒在后，只显示未完成
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
    @Binding var refreshTrigger: Bool

    /// 排序后的所有未完成事件
    private var sortedEvents: [CalendarEvent] {
        _ = refreshTrigger
        let enabledCals = calendarService.enabledCalendars(preferences: calendarPreferences)
        let range = filterMode.dateRange(from: selectedDate)
        let now = Date()
        
        // 收集所有未完成的事件（有时间和全天）
        var timedEvents: [CalendarEvent] = []
        var allDayEvents: [CalendarEvent] = []
        
        // 有时间的事件
        let cachedEvents = calendarService.fetchCachedEvents(
            from: range.start,
            to: range.end,
            calendars: enabledCals
        )
        for event in cachedEvents {
            if !event.isSubscription && !event.isCompleted && event.hasTime {
                timedEvents.append(event)
            }
        }
        
        // 全天事件
        let dayEvents = calendarService.fetchCachedAllDayEvents(
            from: range.start,
            to: range.end,
            calendars: enabledCals
        )
        for event in dayEvents {
            if !event.isSubscription && !event.isCompleted {
                allDayEvents.append(event)
            }
        }
        
        // 合并所有待办事项，统一按时间降序排列
        var allEvents: [CalendarEvent] = timedEvents + allDayEvents
        
        return allEvents.sorted {
            // 1. 首先按时间降序（最新的在前）
            let date0 = $0.startDate ?? .distantPast
            let date1 = $1.startDate ?? .distantPast
            if date0 != date1 {
                return date0 > date1
            }
            // 2. 时间相同则按优先级降序（只有 user 分类才有优先级）
            if $0.category == .user && $1.category == .user {
                return $0.priority > $1.priority
            } else if $0.category == .user {
                return true
            } else if $1.category == .user {
                return false
            }
            return false
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
                    Text("待办事项")
                        .font(.system(size: 12, weight: .semibold))
                    Text("(\(sortedEvents.count))")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            // 可滚动的内容区域
            if isExpanded {
                ScrollView {
                    if sortedEvents.isEmpty {
                        Text("暂无待办事项")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 16)
                    } else {
                        LazyVStack(spacing: 4) {
                            ForEach(sortedEvents) { event in
                                EventItemRow(
                                    event: event,
                                    onEdit: onEditEvent,
                                    onDelete: onDeleteEvent,
                                    onComplete: onCompleteEvent,
                                    isOverdue: event.startDate != nil && event.startDate! < Date()
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
