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

    // 事件驱动的后续刷新防抖（防同步风暴高频重查）
    private func debouncedRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            refreshCachedEvents()
        }
    }

    // 首刷（onAppear）同步立即查询：查询仅毫秒级，先于 .task 全量同步占用主线程执行，
    // 避免重开面板时列表空窗（排在全量同步与月历渲染之后再首刷会空窗约 300ms）
    private func refreshImmediately() {
        refreshTask?.cancel()
        refreshCachedEvents()
    }

    /// 已办列表过滤判定（静态纯函数，可测）：
    /// 无到期时间的任务按「标记完成时间」归档到对应日期范围；
    /// 完成时间缺失（存量未同步补全）时仅在「全部」tab 可见
    static func shouldInclude(
        _ event: CalendarEvent,
        in range: (start: Date, end: Date),
        filterMode: EventFilterMode
    ) -> Bool {
        guard event.category == .user &&
                event.isCompleted &&
                !event.title.trimmingCharacters(in: .whitespaces).isEmpty else {
            return false
        }
        // 无到期时间的任务按「标记完成时间」归档到对应日期范围；
        // 完成时间缺省（存量未同步补全）时仅在「全部」tab 可见
        if event.startDate == nil {
            guard let completedAt = event.completedAt else {
                return filterMode == .all
            }
            return completedAt >= range.start && completedAt < range.end
        }
        return true
    }

    /// 排序生效日期：无到期时间的已办任务按标记完成时间参与排序（无完成时间沉底）
    private func effectiveSortDate(_ event: CalendarEvent) -> Date {
        event.startDate ?? event.completedAt ?? .distantPast
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

        let result = cached.filter { Self.shouldInclude($0, in: range, filterMode: filterMode) }

        var sorted = result
        let isAscending = appSettings.sortOrder == .ascending
        
        switch appSettings.sortMode {
        case .default:
            // 与待办列表（EventTodoListView）口径统一：日期为主键、优先级为次键；
            // 两列表主次键不一致时，同档位设置下待办与已办顺序观感矛盾；
            // 无日期已办的日期键 = 标记完成时间（effectiveSortDate）
            sorted.sort {
                let date0 = effectiveSortDate($0)
                let date1 = effectiveSortDate($1)
                if date0 != date1 {
                    return isAscending ? date0 < date1 : date0 > date1
                }
                return isAscending ? $0.priority < $1.priority : $0.priority > $1.priority
            }
        case .createTime:
            sorted.sort {
                return isAscending ? effectiveSortDate($0) < effectiveSortDate($1) : effectiveSortDate($0) > effectiveSortDate($1)
            }
        case .deadline:
            sorted.sort {
                let date0 = $0.endDate ?? effectiveSortDate($0)
                let date1 = $1.endDate ?? effectiveSortDate($1)
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
            refreshImmediately()
        }
        .onChange(of: refreshTrigger) { _, _ in
            debouncedRefresh()
        }
        .onChange(of: filterMode) { _, _ in
            debouncedRefresh()
        }
        .onChange(of: selectedDate) { _, _ in
            debouncedRefresh()
        }
        // sort-pick-reload：同 EventTodoListView——排序切换需触发重载，
        // 方法体内读 sortMode/sortOrder 不被 Observation 追踪，无触发点则列表不重排
        .onChange(of: appSettings.sortMode) { _, _ in
            debouncedRefresh()
        }
        .onChange(of: appSettings.sortOrder) { _, _ in
            debouncedRefresh()
        }
        // 与 EventTodoListView 一致的广播监听——别处（桌面面板/菜单弹层/过期弹窗）
        // 完成或取消完成后经 .cachedEventsChanged 广播，已办列表与头部计数同步重载；
        // 倒计时归零重建行（countdown-overdue-color-sync）同样适用
        .onReceive(NotificationCenter.default.publisher(for: .cachedEventsChanged)) { _ in
            debouncedRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .countdownExpired)) { _ in
            debouncedRefresh()
        }
    }
}
