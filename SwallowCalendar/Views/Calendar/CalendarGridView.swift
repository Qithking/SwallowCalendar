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
    @State private var subscriptionsLoaded = false  // 用于触发订阅日历数据刷新
    @State private var accentColor: Color = Color(hex: AppSettings.shared.accentColorHex)
    @State private var importantDatesCache: Set<String> = []  // 缓存重要日期
    @State private var subscriptionTitlesCache: [String: [String]] = [:]  // 缓存订阅事件标题
    @State private var eventTitlesCache: [String: [String]] = [:]  // 缓存事件标题
    @State private var eventColorsCache: [String: [String]] = [:]  // 缓存事件颜色

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
            // 预加载订阅日历数据
            await icsService.preloadSubscriptions(sources: customSources)
            subscriptionsLoaded = true
            // 预计算重要日期和事件缓存
            await computeAllCaches()
            print("[CalendarGridView] 订阅日历数据预加载完成")
        }
        .onChange(of: calendarPreferences.map { "\($0.calendarID):\($0.isEnabled):\($0.isImportant)" }.joined()) { _, _ in
            // 日历偏好改变时刷新缓存
            print("[CalendarGridView] 检测到日历偏好变化，刷新所有缓存")
            Task {
                await computeAllCaches()
            }
        }
        .onChange(of: customSources.map { "\($0.icsURL):\($0.isEnabled):\($0.isImportant)" }.joined()) { _, _ in
            // 订阅源改变时刷新缓存
            print("[CalendarGridView] 检测到订阅源变化，刷新所有缓存")
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
        // 使用缓存的订阅事件数据，不再实时计算
        let cachedSubscriptions = subscriptionTitlesCache
        let cachedEventTitles = eventTitlesCache
        let cachedEventColors = eventColorsCache
        _ = subscriptionsLoaded

        return LazyVGrid(columns: columns, spacing: 2) {
            ForEach(days, id: \.self) { date in
                CalendarDayCell(
                    date: date,
                    isSelected: calendar.isDate(date, inSameDayAs: selectedDate),
                    isToday: calendar.isDateInToday(date),
                    isCurrentMonth: calendar.isDate(date, equalTo: currentMonth, toGranularity: .month),
                    lunarText: LunarCalendarHelper.lunarString(for: date),
                    subscriptionTitles: cachedSubscriptions[formatDateKey(date)] ?? [],
                    eventCount: eventCount(for: date),
                    isHovered: hoveredDate.flatMap { calendar.isDate(date, inSameDayAs: $0) } ?? false,
                    eventTitles: cachedEventTitles[formatDateKey(date)] ?? [],
                    eventColors: cachedEventColors[formatDateKey(date)] ?? [],
                    systemCalendarColor: systemCalendarColor(),
                    subscriptionCalendarColor: subscriptionCalendarColor(),
                    isImportant: isImportantDate(for: date)
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
        // 无授权时也从缓存读取
        let enabledCals = calendarService.enabledCalendars(preferences: calendarPreferences)
        let events = calendarService.fetchCachedEvents(for: date, calendars: enabledCals)
        return events.count
    }

    /// 获取所有事件标题（包括订阅日历）- 用于弹出列表显示
    private func allEventTitles(for date: Date) -> [String] {
        // 无授权时也从缓存读取
        let enabledCals = calendarService.enabledCalendars(preferences: calendarPreferences)
        let events = calendarService.fetchCachedEvents(for: date, calendars: enabledCals)
        return events.map { $0.title }
    }

    /// 获取所有事件颜色（包括订阅日历）- 用于弹出列表显示
    private func allEventColors(for date: Date) -> [String] {
        // 无授权时也从缓存读取
        let enabledCals = calendarService.enabledCalendars(preferences: calendarPreferences)
        let events = calendarService.fetchCachedEvents(for: date, calendars: enabledCals)
        return events.map { $0.calendarColorHex }
    }

    /// 获取用户事件标题（不包含订阅日历）- 用于提醒列表
    private func eventTitles(for date: Date) -> [String] {
        // 无授权时也从缓存读取
        let enabledCals = calendarService.enabledCalendars(preferences: calendarPreferences)
        let events = calendarService.fetchCachedEvents(for: date, calendars: enabledCals)
        return events.filter { !$0.isSubscription }.map { $0.title }
    }

    /// 获取用户事件颜色（不包含订阅日历）- 用于提醒列表
    private func eventColors(for date: Date) -> [String] {
        // 无授权时也从缓存读取
        let enabledCals = calendarService.enabledCalendars(preferences: calendarPreferences)
        let events = calendarService.fetchCachedEvents(for: date, calendars: enabledCals)
        return events.filter { !$0.isSubscription }.map { $0.calendarColorHex }
    }

    /// 获取系统日历分类颜色
    private func systemCalendarColor() -> Color {
        return Color(hex: appSettings.systemCalendarColorHex)
    }

    /// 获取自定义日历分类颜色
    private func subscriptionCalendarColor() -> Color {
        return Color(hex: appSettings.subscriptionCalendarColorHex)
    }
    
    /// 预计算所有缓存（重要日期、订阅事件、事件标题、事件颜色）
    func computeAllCaches() async {
        // 预计算订阅事件和事件标题/颜色的缓存
        var subCache: [String: [String]] = [:]
        var titlesCache: [String: [String]] = [:]
        var colorsCache: [String: [String]] = [:]
        
        let days = daysInMonth()
        let enabledCals = calendarService.enabledCalendars(preferences: calendarPreferences)
        
        for date in days {
            let dateKey = formatDateKey(date)
            
            // 订阅事件（只计算有启用订阅源的日期）
            let subTitles = icsService.subscriptionEventsSync(for: date, sources: customSources)
            if !subTitles.isEmpty {
                subCache[dateKey] = subTitles
            }
            
            // 系统日历事件
            let events = calendarService.fetchCachedEvents(for: date, calendars: enabledCals)
            let eventTitles = events.map { $0.title }
            let eventColors = events.map { $0.calendarColorHex }
            if !eventTitles.isEmpty {
                titlesCache[dateKey] = eventTitles
                colorsCache[dateKey] = eventColors
            }
        }
        
        subscriptionTitlesCache = subCache
        eventTitlesCache = titlesCache
        eventColorsCache = colorsCache
        print("[CalendarGridView] 事件缓存已更新，订阅事件: \(subCache.count) 天，事件: \(titlesCache.count) 天")
        
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
        
        for date in days {
            let dateKey = formatDateKey(date)
            
            // 检查系统日历
            if let calendarID = importantCalendarID {
                let cal = calendarService.calendars.first { $0.calendarIdentifier == calendarID }
                if let calendar = cal, hasEventsOnDate(date, in: [calendar]) {
                    dates.insert(dateKey)
                    continue
                }
            }
            
            // 检查订阅日历
            if let source = importantSource {
                let titles = icsService.subscriptionEventsSync(for: date, sources: [source])
                if !titles.isEmpty {
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
    
    /// 检查指定日历在日期是否有事件
    private func hasEventsOnDate(_ date: Date, in calendars: [EKCalendar]) -> Bool {
        guard !calendars.isEmpty, calendarService.authorizationStatus == .fullAccess else { return false }
        
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: date)
        let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay)!
        
        let events = calendarService.fetchEvents(from: startOfDay, to: endOfDay, calendars: calendars)
        return !events.isEmpty
    }
}
