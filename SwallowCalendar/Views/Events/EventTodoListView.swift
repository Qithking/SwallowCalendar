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
        
        // 分离过期和未过期的事件
        var overdueTimed: [CalendarEvent] = []
        var futureTimed: [CalendarEvent] = []
        
        for event in timedEvents {
            if let start = event.startDate {
                if start < now {
                    overdueTimed.append(event)
                } else {
                    futureTimed.append(event)
                }
            }
        }
        
        // 排序（只有 user 分类才有优先级，其他分类优先级为 0）：
        // 1. 已过期有时间的 - 优先级降序，时间降序
        // 2. 未过期有时间的 - 优先级降序，时间升序
        // 3. 无时间的全天事件 - 优先级降序
        
        let sortedOverdue = overdueTimed.sorted {
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
        
        let sortedFuture = futureTimed.sorted {
            if $0.category == .user && $1.category == .user {
                if $0.priority != $1.priority {
                    return $0.priority > $1.priority
                }
            } else if $0.category == .user {
                return true
            } else if $1.category == .user {
                return false
            }
            return ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture)
        }
        
        let sortedAllDay = allDayEvents.sorted {
            if $0.category == .user && $1.category == .user {
                if $0.priority != $1.priority {
                    return $0.priority > $1.priority
                }
            } else if $0.category == .user {
                return true
            } else if $1.category == .user {
                return false
            }
            return ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture)
        }
        
        return sortedOverdue + sortedFuture + sortedAllDay
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
