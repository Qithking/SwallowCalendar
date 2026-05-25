//
//  CalendarGridView.swift
//  SwallowCalendar
//

import SwiftUI
import SwiftData
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

    @State private var currentMonth = Date()
    @State private var hoveredDate: Date?
    @Query private var cachedEvents: [CachedEvent]

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
        let events = cachedEvents
        let enabledCalendarIDs = Set(calendarPreferences.filter { $0.isEnabled }.map { $0.calendarID })
        let importantCalendarID = calendarPreferences.first { $0.isImportant }?.calendarID
        let hasImportantSource = customSources.contains { $0.isImportant && $0.isEnabled }

        return LazyVGrid(columns: columns, spacing: 2) {
            ForEach(days, id: \.self) { date in
                let dayEvents = eventsForDay(date, from: events, enabledCalendarIDs: enabledCalendarIDs)
                let isHovering = hoveredDate.flatMap { calendar.isDate(date, inSameDayAs: $0) } ?? false
                let isImportant = isDayImportant(date, dayEvents: dayEvents, importantCalendarID: importantCalendarID, hasImportantSource: hasImportantSource)

                CalendarDayCell(
                    date: date,
                    isSelected: calendar.isDate(date, inSameDayAs: selectedDate),
                    isToday: calendar.isDateInToday(date),
                    isCurrentMonth: calendar.isDate(date, equalTo: currentMonth, toGranularity: .month),
                    lunarText: LunarCalendarHelper.lunarString(for: date),
                    isHovered: isHovering,
                    eventItems: dayEvents.map { CalendarEventItem(title: $0.title, colorHex: $0.calendarColorHex, category: $0.category.rawValue) },
                    systemCalendarColor: systemCalendarColor(),
                    subscriptionCalendarColor: subscriptionCalendarColor(),
                    isImportant: isImportant
                )
                .background(
                    GeometryReader { geo in
                        CellPopoverPresenter(
                            isPresented: isHovering && !dayEvents.isEmpty,
                            positioningRect: CGRect(origin: .zero, size: geo.size),
                            content: popoverContent(for: date, items: dayEvents.map { CalendarEventItem(title: $0.title, colorHex: $0.calendarColorHex, category: $0.category.rawValue) })
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

    private static let popoverDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()
    
    private func popoverDateString(for date: Date) -> String {
        return Self.popoverDateFormatter.string(from: date)
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

    /// 获取系统日历分类颜色
    private func systemCalendarColor() -> Color {
        return Color(hex: appSettings.systemCalendarColorHex)
    }

    /// 获取自定义日历分类颜色
    private func subscriptionCalendarColor() -> Color {
        return Color(hex: appSettings.subscriptionCalendarColorHex)
    }

    /// 从 CachedEvent 列表中筛选指定日期的事件
    private func eventsForDay(_ date: Date, from events: [CachedEvent], enabledCalendarIDs: Set<String>) -> [CachedEvent] {
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        return events.filter { event in
            guard let start = event.startDate, let end = event.endDate else { return false }
            guard start < endOfDay && end > startOfDay else { return false }
            if event.category == .system {
                return enabledCalendarIDs.isEmpty || enabledCalendarIDs.contains(event.calendarID)
            }
            return true
        }
    }

    /// 判断指定日期是否为重要日期
    private func isDayImportant(_ date: Date, dayEvents: [CachedEvent], importantCalendarID: String?, hasImportantSource: Bool) -> Bool {
        guard importantCalendarID != nil || hasImportantSource else { return false }
        if let calID = importantCalendarID {
            if dayEvents.contains(where: { $0.category == .system && $0.calendarID == calID }) {
                return true
            }
        }
        if hasImportantSource {
            if dayEvents.contains(where: { $0.category == .subscription }) {
                return true
            }
        }
        return false
    }
}
