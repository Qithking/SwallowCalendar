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

        // 收集所有未完成的事件（有时间和全天）
        var timedEvents: [CalendarEvent] = []
        var allDayEvents: [CalendarEvent] = []
        var noDateEvents: [CalendarEvent] = []  // 无到期时间的提醒

        // 有时间的事件（包括系统提醒，包含无到期时间的）
        let cachedEvents = calendarService.fetchCachedEvents(
            from: range.start,
            to: range.end,
            calendars: enabledCals,
            includeNoDateReminders: true
        )
        for event in cachedEvents {
            guard event.category == .user && !event.isCompleted else { continue }
            
            if event.startDate == nil {
                // 无到期时间的提醒
                noDateEvents.append(event)
            } else if event.hasTime {
                timedEvents.append(event)
            } else {
                allDayEvents.append(event)
            }
        }

        // 合并所有待办事项
        // 排序规则：
        // 1. 有时间的按时间降序（最新的在前）
        // 2. 全天事件按时间降序
        // 3. 无到期时间的提醒放在最后
        var allEvents: [CalendarEvent] = timedEvents + allDayEvents
        
        allEvents.sort {
            // 1. 首先按时间降序（最新的在前）
            let date0 = $0.startDate ?? .distantPast
            let date1 = $1.startDate ?? .distantPast
            if date0 != date1 {
                return date0 > date1
            }
            // 2. 时间相同则按优先级降序
            return $0.priority > $1.priority
        }
        
        // 无到期时间的提醒放在最后
        allEvents.append(contentsOf: noDateEvents)

        return allEvents
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
