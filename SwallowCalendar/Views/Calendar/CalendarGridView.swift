//
//  CalendarGridView.swift
//  SwallowCalendar
//

import SwiftUI
import EventKit
import AppKit

// MARK: - NSPopover View Representable

/// 独立的 Coordinator 类，不嵌套在泛型结构体内，
/// 避免 Swift 6.2.4 编译器在 -O -whole-module-optimization 下
/// 对泛型嵌套类的 deinit 进行 EarlyPerfInliner 优化时崩溃。
final class PopoverCoordinator: NSObject, NSPopoverDelegate {
    weak var popover: NSPopover?

    func popoverDidClose(_ notification: Notification) {
        popover = nil
    }
}

/// 使用 NSPopover（独立窗口）不被父视图裁剪，
/// 设置 .behavior = .transient 确保点击 anchor 时关闭 popover 并转发点击事件。
/// placement: 放置在单个 cell 的 background 上，show(relativeTo:of:) 参数值为 cell 的 bounds，
/// positioningRect 来自 GeometryReader 的精确尺寸，箭头指向 rect 上边缘中心。
struct CellPopoverPresenter<Content: View>: NSViewRepresentable {
    let isPresented: Bool
    let positioningRect: CGRect
    let content: Content

    func makeCoordinator() -> PopoverCoordinator {
        PopoverCoordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if isPresented {
            if let popover = context.coordinator.popover, popover.isShown { return }
            let popover = NSPopover()
            popover.behavior = .transient
            popover.delegate = context.coordinator
            popover.contentViewController = NSHostingController(rootView: content)
            popover.show(relativeTo: positioningRect, of: nsView, preferredEdge: .maxY)
            context.coordinator.popover = popover
        } else {
            context.coordinator.popover?.close()
            context.coordinator.popover = nil
        }
    }
}

struct CalendarGridView: View {
    @Environment(AppSettings.self) private var appSettings
    @Binding var selectedDate: Date
    let calendarService: CalendarService
    let customSources: [CustomCalendarSource]
    let calendarPreferences: [CalendarPreference]
    @Binding var externalRefreshTrigger: Bool  // 外部刷新信号

    @State private var currentMonth = Date()
    @State private var hoveredDate: Date?
    @State private var importantDatesCache: Set<String> = []  // 缓存重要日期
    @State private var eventItemsCache: [String: [CalendarEventItem]] = [:]  // 缓存事件条目（标题/颜色/分类三者对齐）
    @State private var isComputing = false  // 计算缓存重入保护

    private let calendar = Calendar.current
    private let weekDaySymbols: [String] = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.veryShortWeekdaySymbols
    }()

    /// 根据 weekdayStart 设置排列的星期符号
    private var orderedWeekDaySymbols: [String] {
        let start = appSettings.weekdayStart // 1=Sunday, 2=Monday
        let index = start - 1
        return Array(weekDaySymbols[index...]) + Array(weekDaySymbols[..<index])
    }

    var body: some View {
        VStack(spacing: 0) {
            // 月份导航头
            CalendarHeaderView(
                currentMonth: $currentMonth,
                selectedDate: $selectedDate
            )

            Divider()

            // 星期标题行
            weekdayHeader

            Divider()

            // 日期网格
            dateGrid
                .padding(.top, 4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .tint(Color(hex: appSettings.accentColorHex))
        .task {
            // 预计算重要日期和事件缓存（订阅同步由 ContentView 统一管理，CalendarGridView 只负责读取）
            await computeAllCaches()
            print("[CalendarGridView] 初始化缓存完成")
        }
        .onChange(of: calendarPreferences.map { "\($0.calendarID):\($0.isEnabled):\($0.isImportant)" }.joined()) { _, _ in
            // 日历偏好改变时刷新缓存
            print("[CalendarGridView] 检测到日历偏好变化，刷新所有缓存")
            Task {
                await computeAllCaches()
            }
        }
        .onChange(of: customSources.map { "\($0.icsURL):\($0.isEnabled):\($0.isImportant)" }.joined()) { _, _ in
            // 订阅源变化时只需刷新缓存（订阅同步由 ContentView 统一管理）
            print("[CalendarGridView] 检测到订阅源变化，刷新缓存")
            Task {
                await computeAllCaches()
            }
        }
        .onChange(of: externalRefreshTrigger) { _, _ in
            // 外部刷新信号（删除/编辑事件后）触发缓存刷新
            print("[CalendarGridView] 检测到外部刷新信号，刷新所有缓存")
            Task {
                await computeAllCaches()
            }
        }
        .onChange(of: currentMonth) { _, _ in
            // 月份改变时刷新缓存
            Task {
                await computeAllCaches()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("CalendarCacheCleared"))) { _ in
            // 清除事件缓存后刷新
            print("[CalendarGridView] 检测到缓存清除通知，刷新所有缓存")
            Task {
                await computeAllCaches()
            }
        }
    }

    // MARK: - Weekday Header

    private var weekdayHeader: some View {
        HStack(spacing: 2) {
            ForEach(orderedWeekDaySymbols.indices, id: \.self) { index in
                Text(orderedWeekDaySymbols[index])
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Date Grid

    private var dateGrid: some View {
        let days = daysInMonth()
        let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
        let cachedEventItems = eventItemsCache
        let dateKeyMap = days.reduce(into: [Date: String]()) { dict, date in
            dict[date] = formatDateKey(date)
        }

        return LazyVGrid(columns: columns, spacing: 2) {
            ForEach(days, id: \.self) { date in
                let dateKey = dateKeyMap[date]!
                let items = cachedEventItems[dateKey] ?? []
                let isHovering = hoveredDate.flatMap { calendar.isDate(date, inSameDayAs: $0) } ?? false

                CalendarDayCell(
                    date: date,
                    isSelected: calendar.isDate(date, inSameDayAs: selectedDate),
                    isToday: calendar.isDateInToday(date),
                    isCurrentMonth: calendar.isDate(date, equalTo: currentMonth, toGranularity: .month),
                    lunarText: LunarCalendarHelper.lunarString(for: date),
                    isHovered: isHovering,
                    eventItems: items,
                    systemCalendarColor: systemCalendarColor(),
                    subscriptionCalendarColor: subscriptionCalendarColor(),
                    isImportant: isImportantDate(for: date)
                )
                .background(
                    GeometryReader { geo in
                        CellPopoverPresenter(
                            isPresented: isHovering && !items.isEmpty,
                            positioningRect: CGRect(origin: .zero, size: geo.size),
                            content: popoverContent(for: date, items: items)
                        )
                    }
                )
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selectedDate = date
                    }
                }
                .onHover { isHovered in
                    hoveredDate = isHovered ? date : nil
                }
            }
        }
    }

    /// 构建指定日期的事件弹出层内容
    private func popoverContent(for date: Date, items: [CalendarEventItem]) -> some View {
        let accents = Color(hex: appSettings.accentColorHex)
        return VStack(alignment: .leading, spacing: 6) {
            Text(popoverDateString(for: date))
                .font(.system(size: 12, weight: .semibold))
            ForEach(items) { item in
                HStack(spacing: 4) {
                    Circle()
                        .fill(popoverItemColor(for: item, accent: accents))
                        .frame(width: 6, height: 6)
                    Text(item.title)
                        .font(.system(size: 11))
                        .lineLimit(2)
                }
            }
        }
        .padding(10)
        .frame(minWidth: 140)
    }

    private func popoverItemColor(for item: CalendarEventItem, accent: Color) -> Color {
        switch item.category {
        case "用户": return accent
        case "系统": return systemCalendarColor()
        case "订阅": return subscriptionCalendarColor()
        default: return systemCalendarColor()
        }
    }

    private func popoverDateString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }

    // MARK: - Helpers

    private func daysInMonth() -> [Date] {
        guard let monthRange = calendar.range(of: .day, in: .month, for: currentMonth) else {
            return []
        }

        let firstDay = calendar.date(from: calendar.dateComponents([.year, .month], from: currentMonth))!
        let weekday = calendar.component(.weekday, from: firstDay)
        // 根据 weekdayStart 计算偏移：使星期列与 orderedWeekDaySymbols 对齐
        let start = appSettings.weekdayStart // 1=Sunday, 2=Monday
        let offset = (weekday - start + 7) % 7

        var days: [Date] = []

        // 填充上月末的日期
        if offset > 0 {
            for i in stride(from: offset, to: 0, by: -1) {
                if let date = calendar.date(byAdding: .day, value: -i, to: firstDay) {
                    days.append(date)
                }
            }
        }

        // 当月日期
        for day in monthRange {
            if let date = calendar.date(byAdding: .day, value: day - 1, to: firstDay) {
                days.append(date)
            }
        }

        // 填充下月初的日期，补全到完整行数
        let remainder = days.count % 7
        if remainder > 0 {
            let lastDay = days.last!
            for i in 1...(7 - remainder) {
                if let date = calendar.date(byAdding: .day, value: i, to: lastDay) {
                    days.append(date)
                }
            }
        }

        return days
    }

    private func eventCount(for date: Date) -> Int {
        let enabledCals = calendarService.enabledCalendars(preferences: calendarPreferences)
        let events = calendarService.fetchCachedEvents(for: date, calendars: enabledCals)
        return events.count
    }

    /// 获取系统日历分类颜色
    private func systemCalendarColor() -> Color {
        return Color(hex: appSettings.systemCalendarColorHex)
    }

    /// 获取自定义日历分类颜色
    private func subscriptionCalendarColor() -> Color {
        return Color(hex: appSettings.subscriptionCalendarColorHex)
    }
    
    /// 预计算所有缓存（事件条目，标题/颜色/分类三者对齐）
    func computeAllCaches() async {
        guard !isComputing else { return }
        isComputing = true
        defer { isComputing = false }

        var itemsCache: [String: [CalendarEventItem]] = [:]
        
        let days = daysInMonth()
        let enabledCals = calendarService.enabledCalendars(preferences: calendarPreferences)
        
        for date in days {
            let dateKey = formatDateKey(date)
            // 统一从 CachedEvent 读取所有事件（包括系统、订阅、用户分类）
            let events = calendarService.fetchCachedEvents(for: date, calendars: enabledCals)
            // 按 eventID 去重兜底：同一日期同一事件只保留一条
            let deduped = Dictionary(grouping: events, by: { $0.id }).compactMapValues { $0.first }.map { $0.value }
            itemsCache[dateKey] = deduped.map { event in
                CalendarEventItem(
                    title: event.title,
                    colorHex: event.calendarColorHex,
                    category: event.category.rawValue
                )
            }
        }
        
        eventItemsCache = itemsCache
        print("[CalendarGridView] 事件缓存已更新，事件: \(itemsCache.count) 天")
        
        // 预计算重要日期
        await computeImportantDates()
    }
    
    /// 预计算重要日期集合
    func computeImportantDates() async {
        var dates: Set<String> = []
        
        // 获取标记为重要的日历
        let importantCalendarID = calendarPreferences.first { $0.isImportant }?.calendarID
        let importantSource = customSources.first { $0.isImportant }
        
        // 如果没有重要的日历或订阅源，直接返回
        if importantCalendarID == nil && importantSource == nil {
            print("[CalendarGridView] 没有设置重要日历或订阅源，清空缓存")
            importantDatesCache = []
            return
        }
        
        // 预计算当前月份的重要日期
        let days = daysInMonth()
        let enabledCals = calendarService.enabledCalendars(preferences: calendarPreferences)
        
        for date in days {
            let dateKey = formatDateKey(date)
            let events = calendarService.fetchCachedEvents(for: date, calendars: enabledCals)
            
            // 检查系统日历重要日历
            if let calendarID = importantCalendarID {
                if events.contains(where: { $0.category == .system && $0.calendarTitle == calendarService.calendars.first(where: { $0.calendarIdentifier == calendarID })?.title }) {
                    dates.insert(dateKey)
                    continue
                }
            }
            
            // 检查订阅日历重要源
            if let source = importantSource {
                if events.contains(where: { $0.category == .subscription && $0.calendarTitle == source.name }) {
                    dates.insert(dateKey)
                }
            }
        }
        
        importantDatesCache = dates
        print("[CalendarGridView] 重要日期缓存已更新，包含 \(dates.count) 个日期")
    }
    
    /// 使用缓存判断日期是否重要
    private func isImportantDate(for date: Date) -> Bool {
        let dateKey = formatDateKey(date)
        return importantDatesCache.contains(dateKey)
    }
    
    /// 格式化日期为字符串键
    private func formatDateKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
