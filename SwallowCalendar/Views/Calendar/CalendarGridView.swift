//
//  CalendarGridView.swift
//  SwallowCalendar
//

import SwiftUI
import EventKit

struct CalendarGridView: View {
    @Environment(AppSettings.self) private var appSettings
    @Binding var selectedDate: Date
    let calendarService: CalendarService
    let icsService: ICSService
    let customSources: [CustomCalendarSource]
    let calendarPreferences: [CalendarPreference]

    @State private var currentMonth = Date()
    @State private var hoveredDate: Date?
    @State private var holidaysLoaded = false  // 用于触发节假日数据刷新
    @State private var accentColor: Color = Color(hex: AppSettings.shared.accentColorHex)

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
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .tint(Color(hex: appSettings.accentColorHex))
        .task {
            // 预加载节假日数据
            await icsService.preloadHolidays(sources: customSources)
            holidaysLoaded = true
            print("[CalendarGridView] 节假日数据预加载完成")
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
        // 使用 holidaysLoaded 触发节假日数据重新计算
        _ = holidaysLoaded

        return LazyVGrid(columns: columns, spacing: 2) {
            ForEach(days, id: \.self) { date in
                CalendarDayCell(
                    date: date,
                    isSelected: calendar.isDate(date, inSameDayAs: selectedDate),
                    isToday: calendar.isDateInToday(date),
                    isCurrentMonth: calendar.isDate(date, equalTo: currentMonth, toGranularity: .month),
                    lunarText: LunarCalendarHelper.lunarString(for: date),
                    holidayNames: icsService.holidayNameSync(for: date),
                    eventCount: eventCount(for: date),
                    isHovered: hoveredDate.flatMap { calendar.isDate(date, inSameDayAs: $0) } ?? false,
                    eventTitles: allEventTitles(for: date),
                    eventColors: allEventColors(for: date)
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
        guard calendarService.authorizationStatus == .fullAccess else { return 0 }
        let enabledCals = calendarService.enabledCalendars(preferences: calendarPreferences)
        // 优先从缓存获取，加快显示速度
        let events = calendarService.fetchCachedEvents(for: date, calendars: enabledCals)
        // 显示所有事件（包括订阅日历的节假日）
        return events.count
    }

    /// 获取所有事件标题（包括订阅日历节假日）- 用于弹出列表显示
    private func allEventTitles(for date: Date) -> [String] {
        guard calendarService.authorizationStatus == .fullAccess else { return [] }
        let enabledCals = calendarService.enabledCalendars(preferences: calendarPreferences)
        // 优先从缓存获取
        let events = calendarService.fetchCachedEvents(for: date, calendars: enabledCals)
        return events.map { $0.title }
    }

    /// 获取所有事件颜色（包括订阅日历节假日）- 用于弹出列表显示
    private func allEventColors(for date: Date) -> [String] {
        guard calendarService.authorizationStatus == .fullAccess else { return [] }
        let enabledCals = calendarService.enabledCalendars(preferences: calendarPreferences)
        // 优先从缓存获取
        let events = calendarService.fetchCachedEvents(for: date, calendars: enabledCals)
        return events.map { $0.calendarColorHex }
    }

    /// 获取用户事件标题（不包含订阅日历）- 用于提醒列表
    private func eventTitles(for date: Date) -> [String] {
        guard calendarService.authorizationStatus == .fullAccess else { return [] }
        let enabledCals = calendarService.enabledCalendars(preferences: calendarPreferences)
        // 优先从缓存获取
        let events = calendarService.fetchCachedEvents(for: date, calendars: enabledCals)
        return events.filter { !$0.isSubscription }.map { $0.title }
    }

    /// 获取用户事件颜色（不包含订阅日历）- 用于提醒列表
    private func eventColors(for date: Date) -> [String] {
        guard calendarService.authorizationStatus == .fullAccess else { return [] }
        let enabledCals = calendarService.enabledCalendars(preferences: calendarPreferences)
        // 优先从缓存获取
        let events = calendarService.fetchCachedEvents(for: date, calendars: enabledCals)
        return events.filter { !$0.isSubscription }.map { $0.calendarColorHex }
    }
}
