//
//  EventPanelView.swift
//  SwallowCalendar
//

import SwiftUI

struct EventPanelView: View {
    let selectedDate: Date
    let calendarService: CalendarService
    let calendarPreferences: [CalendarPreference]

    @State private var filterMode: EventFilterMode = .all

    var body: some View {
        VStack(spacing: 0) {
            // 添加待办输入框（固定顶部）
            TaskInputView(
                calendarService: calendarService,
                calendarPreferences: calendarPreferences
            )
            .padding(.horizontal, 8)
            .padding(.top, 6)

            Divider()
                .padding(.vertical, 4)

            // 快捷过滤条
            EventFilterBar(selectedFilter: $filterMode)
                .padding(.horizontal, 8)

            // 可滚动的倒计时和提醒列表（占满剩余空间）
            ScrollView {
                VStack(spacing: 8) {
                    // 待办倒计时
                    EventCountdownListView(
                        selectedDate: selectedDate,
                        calendarService: calendarService,
                        calendarPreferences: calendarPreferences,
                        filterMode: filterMode
                    )

                    // 提醒
                    EventReminderListView(
                        selectedDate: selectedDate,
                        calendarService: calendarService,
                        calendarPreferences: calendarPreferences,
                        filterMode: filterMode
                    )
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Filter Mode

enum EventFilterMode: String, CaseIterable {
    case today = "今天"
    case thisWeek = "本周"
    case thisMonth = "本月"
    case thisYear = "本年"
    case all = "全部"

    func dateRange(from base: Date) -> (start: Date, end: Date) {
        let calendar = Calendar.current
        let now = Date()

        switch self {
        case .today:
            return (calendar.startOfDay(for: now), calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!)
        case .thisWeek:
            let start = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
            let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start)!
            return (start, end)
        case .thisMonth:
            let start = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
            let end = calendar.date(byAdding: .month, value: 1, to: start)!
            return (start, end)
        case .thisYear:
            let start = calendar.date(from: calendar.dateComponents([.year], from: now))!
            let end = calendar.date(byAdding: .year, value: 1, to: start)!
            return (start, end)
        case .all:
            return (now, calendar.date(byAdding: .year, value: 2, to: now)!)
        }
    }
}
