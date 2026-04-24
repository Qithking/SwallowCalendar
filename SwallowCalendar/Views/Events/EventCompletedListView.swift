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

    private var events: [CalendarEvent] {
        _ = refreshTrigger
        let enabledCals = calendarService.enabledCalendars(preferences: calendarPreferences)
        let range = filterMode.dateRange(from: selectedDate)

        // 从缓存读取事件（包括全天事件和系统提醒，包含无到期时间的）
        let cachedEvents = calendarService.fetchCachedEvents(
            from: range.start,
            to: range.end,
            calendars: enabledCals,
            includeNoDateReminders: true
        )
        
        // 过滤用户创建且已完成的非空事件
        let result = cachedEvents.filter { event in
            event.category == .user &&
            event.isCompleted &&
            !event.title.trimmingCharacters(in: .whitespaces).isEmpty
        }

        // 根据 sortMode 和 sortOrder 排序
        var sorted = result
        let isAscending = appSettings.sortOrder == .ascending
        
        switch appSettings.sortMode {
        case .default:
            // 默认排序：优先级 + 时间
            sorted.sort {
                if $0.priority != $1.priority {
                    return isAscending ? $0.priority < $1.priority : $0.priority > $1.priority
                }
                return isAscending ? ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) : ($0.startDate ?? .distantPast) > ($1.startDate ?? .distantPast)
            }
        case .createTime:
            // 创建时间（按 startDate）
            sorted.sort {
                return isAscending ? ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) : ($0.startDate ?? .distantPast) > ($1.startDate ?? .distantPast)
            }
        case .deadline:
            // 截止时间
            sorted.sort {
                let date0 = $0.endDate ?? $0.startDate ?? .distantPast
                let date1 = $1.endDate ?? $1.startDate ?? .distantPast
                return isAscending ? date0 < date1 : date0 > date1
            }
        case .priority:
            // 优先级
            sorted.sort {
                return isAscending ? $0.priority < $1.priority : $0.priority > $1.priority
            }
        case .title:
            // 标题
            sorted.sort {
                return isAscending ? $0.title < $1.title : $0.title > $1.title
            }
        case .reminder:
            // 系统提醒
            sorted.sort {
                if isAscending {
                    return !$0.isReminder && $1.isReminder
                } else {
                    return $0.isReminder && !$1.isReminder
                }
            }
        }
        
        return sorted
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
                .frame(maxHeight: .infinity)
            }
        }
    }
}
