//
//  EventPanelView.swift
//  SwallowCalendar
//

import SwiftUI

struct EventPanelView: View {
    @Environment(AppSettings.self) private var appSettings
    @Binding var selectedDate: Date
    let calendarService: CalendarService
    let calendarPreferences: [CalendarPreference]
    var externalRefreshTrigger: Bool = false

    @State private var filterMode: EventFilterMode = .thisMonth
    @State private var showDeleteConfirmation = false
    @State private var eventToDelete: CalendarEvent?
    @State private var refreshTrigger = false
    @State private var accentColor: Color = Color(hex: AppSettings.shared.accentColorHex)
    @State private var todoExpanded = true
    @State private var completedExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            // 添加待办输入框（固定顶部）
            TaskInputView(
                calendarService: calendarService,
                calendarPreferences: calendarPreferences,
                refreshTrigger: $refreshTrigger,
                onTaskAdded: {
                    refreshTrigger.toggle()
                }
            )
            .padding(.horizontal, 8)
            .padding(.top, 6)

            Divider()
                .padding(.vertical, 4)

            // 快捷过滤条
            EventFilterBar(selectedFilter: $filterMode)
                .padding(.horizontal, 8)

            // 待办和已办列表（各自独立滚动）
            VStack(spacing: 8) {
                // 待办事项（倒计时 + 提醒合并）
                EventTodoListView(
                    selectedDate: selectedDate,
                    calendarService: calendarService,
                    calendarPreferences: calendarPreferences,
                    filterMode: filterMode,
                    isExpanded: $todoExpanded,
                    onToggle: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            todoExpanded.toggle()
                            if todoExpanded {
                                completedExpanded = false
                            }
                        }
                    },
                    onEditEvent: { event in
                        EditEventWindowManager.shared.openEditWindow(
                            event: event,
                            calendarService: calendarService,
                            onDismiss: {}
                        )
                    },
                    onCompleteEvent: { event in
                        calendarService.toggleEventCompleted(eventID: event.id, isCompleted: true)
                        refreshTrigger.toggle()
                    },
                    onDeleteEvent: { event in
                        eventToDelete = event
                        showDeleteConfirmation = true
                    },
                    refreshTrigger: $refreshTrigger
                )

                // 已办事项
                EventCompletedListView(
                    selectedDate: selectedDate,
                    calendarService: calendarService,
                    calendarPreferences: calendarPreferences,
                    filterMode: filterMode,
                    isExpanded: $completedExpanded,
                    onToggle: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            completedExpanded.toggle()
                            if completedExpanded {
                                todoExpanded = false
                            }
                        }
                    },
                    onEditEvent: { event in
                        EditEventWindowManager.shared.openEditWindow(
                            event: event,
                            calendarService: calendarService,
                            onDismiss: {}
                        )
                    },
                    onUncompleteEvent: { event in
                        calendarService.toggleEventCompleted(eventID: event.id, isCompleted: false)
                        refreshTrigger.toggle()
                    },
                    onDeleteEvent: { event in
                        eventToDelete = event
                        showDeleteConfirmation = true
                    },
                    refreshTrigger: $refreshTrigger
                )
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .overlay {
            if showDeleteConfirmation, let event = eventToDelete {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture {
                        // 点击遮罩不关闭，只有按钮可以关闭
                    }
                DeleteConfirmDialog(
                    eventTitle: event.title,
                    onConfirm: {
                        deleteEvent(event)
                        eventToDelete = nil
                        showDeleteConfirmation = false
                    },
                    onCancel: {
                        eventToDelete = nil
                        showDeleteConfirmation = false
                    }
                )
            }
        }
        .tint(accentColor)
        .onChange(of: appSettings.accentColorHex) { _, newColor in
            accentColor = Color(hex: newColor)
        }
    }

    private func deleteEvent(_ event: CalendarEvent) {
        do {
            try calendarService.deleteEvent(eventID: event.id)
        } catch {
            print("Failed to delete event: \(error)")
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
            let past = calendar.date(byAdding: .year, value: -5, to: now)!
            let future = calendar.date(byAdding: .year, value: 5, to: now)!
            return (past, future)
        }
    }
}
