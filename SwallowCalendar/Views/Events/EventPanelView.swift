//
//  EventPanelView.swift
//  SwallowCalendar
//

import SwiftUI
import AppKit
import os

struct EventPanelView: View {
    @Environment(AppSettings.self) private var appSettings
    @Binding var selectedDate: Date
    let calendarService: CalendarService
    let calendarPreferences: [CalendarPreference]
    var externalRefreshTrigger: Bool = false
    var onEventsChanged: (() -> Void)? = nil  // 事件变更通知回调

    // 初始值即用户默认档：子列表 onAppear 先于父 onAppear 执行，若初始档为 .thisMonth，
    // 同步首刷会先查出全量再被默认档过滤（闪现全部事项）；初始值取默认档则首刷即最终档，
    // 父 onAppear 同值赋值幂等不触发二刷；设置变更仍由下方 onChange 兜底
    @State private var filterMode: EventFilterMode = AppSettings.shared.defaultFilterModeEnum
    @State private var refreshTrigger = false
    // V-18：直接读 appSettings 主题色，替代 @State 复制 + onChange 同步
    private var accentColor: Color { Color(hex: appSettings.accentColorHex) }
    @State private var todoExpanded = true
    @State private var completedExpanded = false
    // 编辑属性态：新建属性表单显示期间隐藏筛选条与待办/已办列表模块
    @State private var isEditingAttributes = false

    var body: some View {
        VStack(spacing: 0) {
            // 添加待办输入框（固定顶部）
            TaskInputView(
                calendarService: calendarService,
                calendarPreferences: calendarPreferences,
                refreshTrigger: $refreshTrigger,
                isEditingAttributes: $isEditingAttributes,
                onTaskAdded: {
                    refreshTrigger.toggle()
                    onEventsChanged?()
                }
            )
            .padding(.horizontal, 8)
            .padding(.top, 6)

            if isEditingAttributes {
                // 编辑属性态：下方区域整个让给属性表单，避免表单与列表层级混杂
                Spacer(minLength: 0)
            } else {
                Divider()
                    .padding(.vertical, 4)

                // 快捷过滤条
                EventFilterBar(selectedFilter: $filterMode)
                    .padding(.horizontal, 8)

                // 待办和已办列表（手风琴效果）
                VStack(spacing: 0) {
                EventTodoListView(
                    selectedDate: selectedDate,
                    calendarService: calendarService,
                    calendarPreferences: calendarPreferences,
                    filterMode: filterMode,
                    isExpanded: $todoExpanded,
                    onToggle: {
                            todoExpanded.toggle()
                            if todoExpanded {
                                completedExpanded = false
                            }
                        },
                    onEditEvent: { event in
                        EditEventWindowManager.shared.openEditWindow(
                            event: event,
                            calendarService: calendarService,
                            onDismiss: {},
                            onSave: {
                                refreshTrigger.toggle()
                                onEventsChanged?()
                            }
                        )
                    },
                    onCompleteEvent: { event in
                        Task {
                            // V-2：先 await 数据变更完成，再触发刷新，避免列表回显旧状态
                            await calendarService.toggleEventCompleted(eventID: event.id, isCompleted: true, isReminder: event.isReminder)
                            // D2/G7v2：完成路径广播缓存变更（徽标即时刷新）
                            NotificationCenter.default.post(name: .cachedEventsChanged, object: nil)
                            refreshTrigger.toggle()
                        }
                    },
                    onDeleteEvent: { event in
                        showDeleteConfirmation(event: event)
                    },
                    refreshTrigger: $refreshTrigger
                )
                
                if todoExpanded {
                    Spacer()
                }
                
                EventCompletedListView(
                    selectedDate: selectedDate,
                    calendarService: calendarService,
                    calendarPreferences: calendarPreferences,
                    filterMode: filterMode,
                    isExpanded: $completedExpanded,
                    onToggle: {
                        completedExpanded.toggle()
                        if completedExpanded {
                            todoExpanded = false
                        }
                    },
                    onEditEvent: { event in
                        EditEventWindowManager.shared.openEditWindow(
                            event: event,
                            calendarService: calendarService,
                            onDismiss: {},
                            onSave: {
                                refreshTrigger.toggle()
                                onEventsChanged?()
                            }
                        )
                    },
                    onUncompleteEvent: { event in
                        Task {
                            // V-2：先 await 数据变更完成，再触发刷新，避免列表回显旧状态
                            await calendarService.toggleEventCompleted(eventID: event.id, isCompleted: false, isReminder: event.isReminder)
                            // D2/G7v2：取消完成同样改变未完成集合，广播缓存变更（徽标即时刷新）
                            NotificationCenter.default.post(name: .cachedEventsChanged, object: nil)
                            refreshTrigger.toggle()
                        }
                    },
                    onDeleteEvent: { event in
                        showDeleteConfirmation(event: event)
                    },
                    refreshTrigger: $refreshTrigger
                )
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isEditingAttributes)
        // V-36：通知/设置监听从 EmptyView hacky 写法迁移到根视图修饰符（语义等价、写法正规）
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SystemCalendarPreferencesChanged"))) { _ in
            refreshTrigger.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SubscriptionSourcesChanged"))) { _ in
            refreshTrigger.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CalendarCacheCleared"))) { _ in
            // V-6：缓存被清空后立即刷新列表，避免展示已删除的旧数据
            refreshTrigger.toggle()
        }
        .onChange(of: appSettings.syncSystemReminders) { _, _ in
            refreshTrigger.toggle()
        }
        .onAppear {
            filterMode = appSettings.defaultFilterModeEnum
        }
        .onChange(of: appSettings.defaultFilterModeEnum) { _, newMode in
            filterMode = newMode
        }
        .tint(accentColor)
    }

    // MARK: - Delete Confirmation with NSAlert

    @MainActor
    private func showDeleteConfirmation(event: CalendarEvent) {
        // 单条化 plan step 8：循环任务只存一条，不再依赖 groupId 判定
        let isRecurring = event.recurrenceType != .none

        let alert = NSAlert()
        alert.messageText = "确认删除"

        if isRecurring {
            // 单条化：删循环任务 = 删整条（应用 + EK 各 1 条），不再区分「删除此项/删除全部」
            alert.informativeText = "确定要删除循环任务「\(event.title)」吗？\n将删除该任务的全部安排，此操作无法撤销。"
        } else {
            alert.informativeText = "确定要删除事件「\(event.title)」吗？\n此操作无法撤销。"
        }

        alert.alertStyle = .warning

        // 非周期任务与循环任务统一两按钮（循环任务删除即删整条）
        alert.addButton(withTitle: "取消")  // 第一个按钮
        let deleteButton = alert.addButton(withTitle: "删除")  // 第二个按钮
        deleteButton.hasDestructiveAction = true

        // 显示对话框
        let response = alert.runModal()

        // NSAlert 按钮索引从 1000 开始：1001 = 第二个按钮（删除）
        if response.rawValue == 1001 {
            deleteEvent(event)
        }
    }

    private func deleteEvent(_ event: CalendarEvent) {
        do {
            try calendarService.deleteEvent(eventID: event.id, isReminder: event.isReminder)
            refreshTrigger.toggle()
            onEventsChanged?()
        } catch {
            AppLogger.ui.error("删除事件失败: \(String(describing: error))")
        }
    }
}

// MARK: - Filter Mode

enum EventFilterMode: String, CaseIterable, Codable {
    case today = "今天"
    case thisWeek = "本周"
    case thisMonth = "本月"
    case thisYear = "本年"
    case all = "全部"

    func dateRange(from base: Date) -> (start: Date, end: Date) {
        let calendar = Calendar.current
        
        // 根据设置确定一周起始日（1=周日，2=周一）
        var cal = calendar
        cal.firstWeekday = AppSettings.shared.weekdayStart

        switch self {
        case .today:
            return (cal.startOfDay(for: base), cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: base))!)
        case .thisWeek:
            // 手动计算 base 所在周的开始（考虑 firstWeekday）
            let weekday = cal.component(.weekday, from: base)
            let daysFromWeekStart = weekday - cal.firstWeekday
            let normalizedDaysFromStart = daysFromWeekStart < 0 ? daysFromWeekStart + 7 : daysFromWeekStart
            let start = cal.startOfDay(for: cal.date(byAdding: .day, value: -normalizedDaysFromStart, to: base)!)
            let end = cal.date(byAdding: .day, value: 7, to: start)!
            return (start, end)
        case .thisMonth:
            let start = cal.date(from: cal.dateComponents([.year, .month], from: base))!
            let end = cal.date(byAdding: .month, value: 1, to: start)!
            return (start, end)
        case .thisYear:
            let start = cal.date(from: cal.dateComponents([.year], from: base))!
            let end = cal.date(byAdding: .year, value: 1, to: start)!
            return (start, end)
        case .all:
            // V-22："全部"语义修正为真全部（与 ICS 导出语义一致），
            // 不再隐含 ±5 年窗口，避免用户 5 年前/后的历史事项在"全部"视图不可见
            return (.distantPast, .distantFuture)
        }
    }
}
