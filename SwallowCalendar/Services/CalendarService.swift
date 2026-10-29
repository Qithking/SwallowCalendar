//
//  CalendarService.swift
//  SwallowCalendar
//

import EventKit
import SwiftUI
import SwiftData
import os

@Observable
final class CalendarService {
    static let shared = CalendarService()

    private let eventStore = EKEventStore()
    var authorizationStatus: EKAuthorizationStatus = .notDetermined
    var reminderAuthorizationStatus: EKAuthorizationStatus = .notDetermined
    var calendars: [EKCalendar] = []
    var isLoading = false
    
    /// 事件缓存服务
    let cacheService = EventCacheService.shared

    // internal 供测试 @testable 使用
    init() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        reminderAuthorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
    }

    // MARK: - Public Methods

    // MARK: - Authorization

    /// 请求 EventKit 权限
    /// - Parameter requestReminders: S-7：是否同时请求提醒权限——提醒同步默认关闭，
    ///   关闭时不应无条件索要提醒 fullAccess
    /// 返回 (日历授权成功, 提醒授权成功)
    @MainActor
    func requestAccess(requestReminders: Bool) async -> (calendar: Bool, reminder: Bool) {
        do {
            // 按需请求：日历必请求，提醒仅在开启同步时请求
            let eventResult = try await eventStore.requestFullAccessToEvents()
            var reminderResult = false
            if requestReminders {
                reminderResult = try await eventStore.requestFullAccessToReminders()
                reminderAuthorizationStatus = reminderResult ? .fullAccess : .denied
            } else {
                // 未请求提醒权限时保留现有状态，不覆盖为 denied
                reminderResult = reminderAuthorizationStatus == .fullAccess
            }

            authorizationStatus = eventResult ? .fullAccess : .denied

            if eventResult {
                loadCalendars()
            }

            return (eventResult, reminderResult)
        } catch {
            authorizationStatus = .denied
            if requestReminders {
                reminderAuthorizationStatus = .denied
            }
            return (false, false)
        }
    }

    /// 打开系统设置中的提醒权限页面
    func openReminderSettings() {
        // 尝试打开系统设置 - 隐私与安全性 - 提醒事项
        if let url = URL(string: "x-apple.systempreferences://com.apple.preference.security?Privacy_Reminders") {
            if NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - Calendars

    @MainActor
    func loadCalendars() {
        calendars = eventStore.calendars(for: .event)
    }

    /// 获取已启用的日历（根据用户偏好过滤）
    /// - 新用户（preferences 为空）：返回所有系统日历
    /// - 所有日历已关闭（enabledIDs 为空）：返回空数组，不同步任何系统日历数据
    /// - 有开启的日历：只返回开启的日历
    func enabledCalendars(preferences: [CalendarPreference]) -> [EKCalendar] {
        let enabledIDs = Set(preferences.filter(\.isEnabled).map(\.calendarID))

        if preferences.isEmpty {
            // 新用户，还没有任何偏好配置，返回所有系统日历（包括系统订阅日历，统一归为系统分类）
            return calendars
        }

        if enabledIDs.isEmpty {
            // 所有日历都已关闭，返回空数组（不同步任何系统日历数据）
            return []
        }

        // 只返回用户明确开启的日历
        return calendars.filter { enabledIDs.contains($0.calendarIdentifier) }
    }

    /// 初始同步成功后默认勾选全部系统日历（幂等：已存在任一偏好记录则跳过，尊重用户已做选择）
    /// - Note: 修复「设置页未勾选却显示系统日历内容」——原实现无偏好记录时
    ///   enabledCalendars 兜底全量同步/显示，而设置页 Toggle 按"无记录=未勾"渲染，两侧语义不一致；
    ///   首次同步成功后落库全勾记录，此后同步、设置页、日历网格三处均以记录为唯一口径
    @MainActor
    func seedDefaultCalendarPreferences(context: ModelContext, preferences: [CalendarPreference], calendars: [EKCalendar]) {
        guard preferences.isEmpty, !calendars.isEmpty else { return }
        for calendar in calendars {
            context.insert(CalendarPreference(calendarID: calendar.calendarIdentifier, isEnabled: true))
        }
        do {
            try context.save()
        } catch {
            AppLogger.sync.error("默认勾选系统日历写入失败: \(String(describing: error))")
        }
    }

    // MARK: - Events

    /// 获取指定日期范围的事件
    func fetchEvents(from startDate: Date, to endDate: Date, calendars: [EKCalendar]? = nil) -> [CalendarEvent] {
        let predicate = eventStore.predicateForEvents(
            withStart: startDate,
            end: endDate,
            calendars: calendars
        )
        let ekEvents = eventStore.events(matching: predicate)
        return ekEvents.map { mapToCalendarEvent($0) }
    }
    
    /// 从缓存获取指定日期范围的事件（优先使用缓存，加快启动速度）
    /// - Note: 默认不包含无到期时间的系统提醒（用于日历视图）
    @MainActor
    func fetchCachedEvents(from startDate: Date, to endDate: Date, calendars: [EKCalendar]? = nil, includeNoDateReminders: Bool = false) -> [CalendarEvent] {
        let cached = cacheService.getEvents(from: startDate, to: endDate, calendars: calendars, includeNoDateReminders: includeNoDateReminders)
        return cached.map { cachedToCalendarEvent($0) }
    }

    /// 获取某天的事件
    func fetchEvents(for date: Date, calendars: [EKCalendar]? = nil) -> [CalendarEvent] {
        let (start, end) = dayRange(for: date)
        return fetchEvents(from: start, to: end, calendars: calendars)
    }
    
    /// 从缓存获取某天的事件（优先使用缓存）
    /// - Note: 默认不包含无到期时间的系统提醒（用于日历视图）
    @MainActor
    func fetchCachedEvents(for date: Date, calendars: [EKCalendar]? = nil, includeNoDateReminders: Bool = false) -> [CalendarEvent] {
        let cached = cacheService.getEvents(for: date, calendars: calendars, includeNoDateReminders: includeNoDateReminders)
        return cached.map { cachedToCalendarEvent($0) }
    }

    /// 从缓存获取全天事件
    /// - Note: 包含无到期时间的系统提醒（用于待办列表）
    @MainActor
    func fetchCachedAllDayEvents(from startDate: Date, to endDate: Date, calendars: [EKCalendar]? = nil) -> [CalendarEvent] {
        var events = fetchCachedEvents(from: startDate, to: endDate, calendars: calendars, includeNoDateReminders: true)
        events = events.filter(\.isAllDay)
        events.sort { $0.startDate ?? .distantFuture < $1.startDate ?? .distantFuture }
        return events
    }

    // MARK: - Reminders

    /// 获取系统提醒（待办事项）
    /// - Parameters:
    ///   - includeCompleted: 是否包含已完成的提醒，默认 false
    ///   - from: 可选的开始日期，用于过滤有到期时间的提醒
    ///   - to: 可选的结束日期，用于过滤有到期时间的提醒
    /// - Note: 没有到期时间的提醒不受日期范围限制，始终返回
    func fetchReminders(includeCompleted: Bool = false, from: Date? = nil, to: Date? = nil) async -> [CalendarEvent] {
        guard reminderAuthorizationStatus == .fullAccess else {
            return []
        }

        let predicate = eventStore.predicateForReminders(in: nil)

        return await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                let all = reminders ?? []
                // bug: ek-recurrence-materialization-mirror——Apple 对循环提醒按「发生」物化为
                // 独立 EKReminder，历史发生以已完成态落库。锚集合 = 带规则的未完成条目，
                // 同 title 已完成条目即物化历史，不入库（syncReminders 按返回集差集自动删缓存）
                let anchorTitles = Set(
                    all.filter { !$0.isCompleted && !($0.recurrenceRules ?? []).isEmpty }
                       .compactMap { $0.title }
                )
                // 同 title 已完成历史到期序列：EK 无 hourly 表达（每小时/每天均 daily），
                // 借物化历史间隔推断真实档位
                let historyDueDates = Self.completedDueDatesByTitle(from: all)
                let mappedReminders = all.compactMap { reminder -> CalendarEvent? in
                    // 过滤已完成项（根据参数决定）
                    if !includeCompleted && reminder.isCompleted {
                        return nil
                    }
                    // 物化历史不入库（锚条目法）
                    if Self.isMaterializedHistory(
                        isCompleted: reminder.isCompleted,
                        title: reminder.title ?? "",
                        anchorTitles: anchorTitles
                    ) {
                        return nil
                    }

                    // 判断是否有到期时间
                    if let dueDate = reminder.dueDateComponents?.date {
                        // 有到期时间的提醒：按照日期范围过滤
                        if let start = from, dueDate < start {
                            return nil
                        }
                        if let end = to, dueDate > end {
                            return nil
                        }
                        return self.mapReminderToCalendarEvent(
                            reminder, dueDate: dueDate,
                            historyDueDates: historyDueDates[reminder.title ?? ""] ?? []
                        )
                    } else {
                        // 没有到期时间的提醒：不受日期范围限制，直接返回
                        return self.mapReminderToCalendarEvent(
                            reminder, dueDate: nil,
                            historyDueDates: historyDueDates[reminder.title ?? ""] ?? []
                        )
                    }
                }

                continuation.resume(returning: mappedReminders)
            }
        }
    }

    /// 通过 eventID 全量查找 EKReminder 对象
    /// 用于 calendarItem(withIdentifier:) 查不到已完成 iCloud 提醒时的兜底
    private func fetchReminderObject(byID id: String) async -> EKReminder? {
        let predicate = eventStore.predicateForReminders(in: nil)
        return await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders?.first { $0.calendarItemIdentifier == id })
            }
        }
    }

    /// 将 EKReminder 转换为 CalendarEvent
    /// - Parameters:
    ///   - historyDueDates: 同 title 已完成历史到期序列（daily 歧义档位推断上下文）
    private func mapReminderToCalendarEvent(
        _ reminder: EKReminder,
        dueDate: Date?,
        historyDueDates: [Date] = []
    ) -> CalendarEvent {
        let isAllDay: Bool
        if dueDate != nil {
            isAllDay = reminder.dueDateComponents?.hour == nil && reminder.dueDateComponents?.minute == nil
        } else {
            isAllDay = true  // 无到期时间的提醒视为全天事件
        }
        return CalendarEvent(
            id: reminder.calendarItemIdentifier,
            title: reminder.title ?? "",
            startDate: dueDate,
            endDate: dueDate,
            isAllDay: isAllDay,
            calendarID: reminder.calendar?.calendarIdentifier ?? "",
            calendarTitle: reminder.calendar?.title ?? "提醒",
            calendarColorHex: reminder.calendar?.cgColor?.hexString ?? "#FF9500",
            category: .user,
            isCompleted: reminder.isCompleted,
            priority: 0,
            isReminder: true,
            recurrenceType: Self.mapRecurrenceRule(
                reminder.recurrenceRules?.first,
                historyDueDates: historyDueDates
            ),
            reminderMinutes: Self.extractReminderMinutes(from: reminder.alarms),
            reminderOffsets: Self.extractReminderOffsets(from: reminder.alarms),
            // absolute 准点闹钟（任务 E 模式）标记：sync 回流时保留缓存提前提醒
            reminderAlarmIsAbsolute: Self.hasAbsoluteReminderAlarm(reminder.alarms),
            eventColorHex: nil
        )
    }

    /// EK 规则 → 应用档位（bug: ek-recurrence-materialization-mirror）
    /// - EK 无 hourly 表达：每小时与每天同为 daily/interval=1，freqRaw=0 为歧义档，
    ///   借同 title 物化历史到期间隔众数推断（1h → .hourly，否则 .daily；无历史 fallback .daily）
    /// - weekly/monthly/yearly 直接映射；应用自建提醒不写规则，映射恒 .none 不受影响
    static func mapRecurrenceRule(_ rule: EKRecurrenceRule?, historyDueDates: [Date]) -> RecurrenceType {
        guard let rule else { return .none }
        switch rule.frequency {
        case .weekly: return .weekly
        case .monthly: return .monthly
        case .yearly: return .yearly
        case .daily: return inferDailyGrade(historyDueDates: historyDueDates)
        @unknown default: return .none
        }
    }

    /// daily 歧义档推断：相邻到期间隔众数为 1 小时 → 每小时，否则每天
    static func inferDailyGrade(historyDueDates: [Date]) -> RecurrenceType {
        let sorted = historyDueDates.sorted()
        guard sorted.count >= 2 else { return .daily }
        var gapCounts: [TimeInterval: Int] = [:]
        for i in 1..<sorted.count {
            let gap = sorted[i].timeIntervalSince(sorted[i - 1])
            gapCounts[gap, default: 0] += 1
        }
        let modeGap = gapCounts.max { $0.value < $1.value }?.key ?? 0
        return modeGap == 3600 ? .hourly : .daily
    }

    /// 物化历史判定（锚条目法）：已完成 && title 属于某条带规则未完成锚条目
    /// → Apple 物化的历史发生，不入库；应用自建提醒无 EK 规则，永不为锚
    static func isMaterializedHistory(isCompleted: Bool, title: String, anchorTitles: Set<String>) -> Bool {
        isCompleted && anchorTitles.contains(title)
    }

    /// 全量条目按 title 归组已完成到期序列（物化历史间隔推断数据源）
    private static func completedDueDatesByTitle(from reminders: [EKReminder]) -> [String: [Date]] {
        var result: [String: [Date]] = [:]
        for reminder in reminders where reminder.isCompleted {
            if let due = reminder.dueDateComponents?.date, let title = reminder.title {
                result[title, default: []].append(due)
            }
        }
        return result
    }

    /// 从 EKAlarm 数组中提取最早的提醒提前分钟数
    private static func extractReminderMinutes(from alarms: [EKAlarm]?) -> Int {
        guard let alarms = alarms else { return 0 }
        var maxMinutes = 0
        for alarm in alarms {
            // relativeOffset < 0 表示在事件之前提醒
            if alarm.relativeOffset < 0 {
                let minutes = Int(-alarm.relativeOffset / 60)
                if minutes > maxMinutes {
                    maxMinutes = minutes
                }
            }
        }
        return maxMinutes
    }

    /// 从 EKAlarm 数组提取完整提醒提前分钟数组（多级，plan 步骤 7）
    /// 与 extractReminderMinutes 同口径（仅相对偏移 alarm）；去重升序；
    /// 无有效 alarm 返回 nil（未设置多级语义）
    static func extractReminderOffsets(from alarms: [EKAlarm]?) -> [Int]? {
        guard let alarms else { return nil }
        let offsets = Set(alarms.compactMap { alarm -> Int? in
            guard alarm.relativeOffset < 0 else { return nil }
            return Int(-alarm.relativeOffset / 60)
        }).sorted()
        return offsets.isEmpty ? nil : offsets
    }

    /// EK 闹钟数组是否含 absolute（绝对时刻）闹钟：任务 E 模式（bug: reminder-app-shows-advanced-time）
    /// 下应用为 EKReminder 写准点 absolute(due) 闹钟，EK 侧不含提前量
    /// （bug: reminder-offsets-wiped-by-sync，提前提醒由应用内缓存承担）
    /// - Note: 判据为 absoluteDate 非 nil；macOS 上 absolute 闹钟的 relativeOffset
    ///   呈现为 0 而非 nil（ReminderAlarmAbsoluteTests 实证），不可用 relativeOffset 判定
    static func hasAbsoluteReminderAlarm(_ alarms: [EKAlarm]?) -> Bool {
        alarms?.contains { $0.absoluteDate != nil } ?? false
    }

    /// 生成 EKAlarm 数组：多级 offsets 非空时逐档生成；否则按单级 minutes 兼容口径
    /// - reminderDueDate 非空（EKReminder 路径）：对齐 Apple 自家存储模式，系统侧写
    ///   absolute(due) 准点闹钟——macOS 提醒 app 将相对闹钟渲染为「提醒我 T-offset」
    ///   单一告警（bug: reminder-app-shows-advanced-time），提前提醒由应用内缓存
    ///   reminderOffsets 承担；未设置提前提醒时保持无闹钟
    static func makeAlarms(offsets: [Int]?, minutes: Int?, reminderDueDate: Date? = nil) -> [EKAlarm] {
        // 提醒路径：设置了提前提醒（多级或单级）→ 系统侧仅写准点绝对闹钟
        if let due = reminderDueDate {
            if offsets?.isEmpty == false || (minutes ?? 0) > 0 {
                return [EKAlarm(absoluteDate: due)]
            }
            return []
        }
        // 事件路径：相对偏移闹钟，系统日历通知按提前量触发
        if let offsets, !offsets.isEmpty {
            return offsets.map { EKAlarm(relativeOffset: TimeInterval(-$0 * 60)) }
        }
        if let minutes, minutes > 0 {
            return [EKAlarm(relativeOffset: TimeInterval(-minutes * 60))]
        }
        return []
    }

    // MARK: - CRUD

    /// 创建日历事件或提醒
    /// - Note: 如果 asReminder 为 true，则创建到系统提醒；否则创建到系统日历
    /// - Note: 循环任务单条化（plan step 4）：只创建单条 EK 记录 + 缓存行（recurrenceType 标记），
    ///         序列由 getEvents 虚拟展开、完成由 startDate 推进，不再生成多实例
    @MainActor
    func createEvent(
        title: String,
        startDate: Date,
        endDate: Date?,
        isAllDay: Bool,
        calendar: EKCalendar?,
        priority: EventPriority? = nil,
        recurrence: RecurrenceType? = nil,
        reminderMinutes: Int? = nil,
        reminderOffsets: [Int]? = nil,
        category: EventCategory = .system,
        asReminder: Bool = false,
        isLunar: Bool = false,
        color: EventColor? = nil,
        skipHolidays: Bool = false,
        validity: ValidityPeriod? = nil
    ) throws {
        let recurrenceType = recurrence ?? .none
        
        // 周期任务需要确保时间在当前时间之后
        var finalStartDate = startDate
        var finalEndDate = endDate
        if recurrenceType != .none {
            // E-4：全天事件的 startDate=当日 00:00，恒早于 Date()，
            // 会把当天创建的"每天"全天事项首实例错误推进到明天；
            // 全天只需早于今天零点才算已过期，带时间保持 <= 当前时刻
            let isOverdue = isAllDay
                ? startDate < Calendar.current.startOfDay(for: Date())
                : startDate <= Date()
            if isOverdue {
                // 周期任务：如果时间已过，推进到下一个周期
                finalStartDate = CalendarService.advanceRecurrenceDate(startDate, recurrenceType: recurrenceType)
                
                // 同时推进 endDate（如果有）
                if let ed = endDate {
                    let timeDiff = ed.timeIntervalSince(startDate)
                    finalEndDate = finalStartDate.addingTimeInterval(timeDiff)
                }
            }
        }
        
        // 循环任务：单条创建（recurrenceType 写入缓存，EK 侧为普通单条记录、无重复规则）
        if recurrenceType != .none {
            // 全天事件的结束日期是第二天，否则 EventKit 会报错
            let eventEndDate: Date? = {
                if isAllDay {
                    return Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: finalStartDate))
                } else {
                    return finalEndDate ?? finalStartDate.addingTimeInterval(3600)
                }
            }()

            if asReminder {
                try createReminderWithGroupInfo(
                    title: title,
                    dueDate: finalStartDate,
                    isAllDay: isAllDay,
                    priority: priority,
                    recurrenceType: recurrenceType,
                    isLunar: isLunar,
                    reminderMinutes: reminderMinutes,
                    color: color,
                    skipHolidays: skipHolidays,
                    // 有效期透传（spec AC-6，plan step 6）：仅循环分支携带
                    validity: validity
                )
            } else {
                try createCalendarEventWithGroupInfo(
                    title: title,
                    startDate: finalStartDate,
                    endDate: eventEndDate,
                    isAllDay: isAllDay,
                    calendar: calendar,
                    priority: priority,
                    reminderMinutes: reminderMinutes,
                    category: category,
                    recurrenceType: recurrenceType,
                    isLunar: isLunar,
                    color: color,
                    skipHolidays: skipHolidays,
                    validity: validity
                )
            }
        } else {
            // 非周期任务，创建一个（允许过去时间）
            if asReminder {
                try createReminder(
                    title: title,
                    dueDate: startDate,
                    isAllDay: isAllDay,
                    priority: priority,
                    recurrence: nil,
                    reminderMinutes: reminderMinutes,
                    color: color,
                    skipHolidays: skipHolidays
                )
            } else {
                try createCalendarEvent(
                    title: title,
                    startDate: startDate,
                    endDate: endDate,
                    isAllDay: isAllDay,
                    calendar: calendar,
                    priority: priority,
                    recurrence: nil,
                    reminderMinutes: reminderMinutes,
                    category: category,
                    color: color,
                    skipHolidays: skipHolidays
                )
            }
        }
    }
    
    /// 创建系统日历事件
    @MainActor
    private func createCalendarEvent(
        title: String,
        startDate: Date,
        endDate: Date?,
        isAllDay: Bool,
        calendar: EKCalendar?,
        priority: EventPriority? = nil,
        recurrence: RecurrenceType? = nil,
        reminderMinutes: Int? = nil,
        reminderOffsets: [Int]? = nil,
        category: EventCategory = .system,
        color: EventColor? = nil,
        skipHolidays: Bool = false
    ) throws {
        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = startDate
        // 全天事件的结束日期必须是第二天，否则EventKit会报错
        if isAllDay {
            event.endDate = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: startDate)) ?? startDate.addingTimeInterval(86400)
        } else {
            let calculatedEndDate = endDate ?? startDate.addingTimeInterval(3600)
            // 确保 endDate > startDate
            if calculatedEndDate <= startDate {
                event.endDate = startDate.addingTimeInterval(3600)
            } else {
                event.endDate = calculatedEndDate
            }
        }
        event.isAllDay = isAllDay
        let targetCalendar = calendar ?? eventStore.defaultCalendarForNewEvents ?? calendars.first
        event.calendar = targetCalendar

        // 设置重复规则
        if let recurrence = recurrence, recurrence != .none {
            let freq: EKRecurrenceFrequency
            switch recurrence {
            case .daily, .unlimited: freq = .daily
            case .weekly: freq = .weekly
            case .monthly: freq = .monthly
            case .yearly: freq = .yearly
            case .none, .custom, .hourly: freq = .daily
            }
            let rule = EKRecurrenceRule(recurrenceWith: freq, interval: 1, end: nil)
            event.addRecurrenceRule(rule)
        }

        // 设置提醒（仅当用户指定时才添加）：多级 offsets 优先，单级 minutes 兼容
        event.alarms = Self.makeAlarms(offsets: reminderOffsets, minutes: reminderMinutes)

        guard event.calendar != nil else {
            throw EventError.noCalendarAvailable
        }
        
        // B-5：用户分类事件一律打来源标记（与 syncEventsToSystem 开关无关）。
        // 原因：事件总是写入系统日历，若不打标记，清缓存后 syncEvents 会将其
        // 误归为 .system，系统日历侧删除时缓存会被连带误删（.user 本应跳过）。
        if category == .user {
            event.notes = "此事项来自SwallowCalendar应用"
        }
        
        try eventStore.save(event, span: .thisEvent)
        
        // 保存到本地缓存
        if let context = cacheService.context {
            let cached = CachedEvent(
                eventID: event.eventIdentifier,
                title: event.title ?? "",
                startDate: event.startDate,
                endDate: event.endDate,
                isAllDay: event.isAllDay,
                calendarID: event.calendar.calendarIdentifier,
                calendarTitle: event.calendar.title,
                calendarColorHex: event.calendar.cgColor?.hexString ?? "#007AFF",
                category: category,
                priority: priority?.rawValue ?? 0,
                reminderMinutes: reminderMinutes ?? 0,
                eventColorHex: color?.rawValue,
                skipHolidays: skipHolidays
            )
            // 多级提醒：经 setter 写入以维护硬不变量 reminderMinutes == offsets.max()
            if let offsets = reminderOffsets, !offsets.isEmpty {
                cached.reminderOffsets = offsets
            }
            context.insert(cached)
            do {
                try context.save()
            } catch {
                AppLogger.sync.error("缓存同步失败: \(String(describing: error))")
            }
        }
    }

    /// B-33：EventPriority（9=最高）→ EKReminder.priority（1=最高、9=最低、0=无）语义映射
    private static func ekPriority(from priority: EventPriority?) -> Int {
        // 先解包再 switch：EventPriority 自带 .none case，对 Optional 直接 switch 时
        // `case .none` 被解析为 Optional.none（与 nil 重复），.some(EventPriority.none)
        // 未覆盖会导致运行时崩溃，且穷尽性判定依赖编译器版本
        guard let priority else { return 0 }
        switch priority {
        case .high: return 1
        case .medium: return 5
        case .low: return 9
        case .none: return 0
        }
    }
    
    /// 创建系统提醒
    @MainActor
    private func createReminder(
        title: String,
        dueDate: Date,
        isAllDay: Bool,
        priority: EventPriority? = nil,
        recurrence: RecurrenceType? = nil,
        reminderMinutes: Int? = nil,
        reminderOffsets: [Int]? = nil,
        color: EventColor? = nil,
        skipHolidays: Bool = false
    ) throws {
        guard reminderAuthorizationStatus == .fullAccess else {
            throw EventError.noReminderAccess
        }
        
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = title
        reminder.calendar = eventStore.defaultCalendarForNewReminders() ?? eventStore.calendars(for: .reminder).first
        guard reminder.calendar != nil else {
            throw EventError.noReminderCalendarAvailable
        }
        
        // 设置到期时间
        var components = Calendar.current.dateComponents([.year, .month, .day], from: dueDate)
        if !isAllDay {
            components.hour = Calendar.current.component(.hour, from: dueDate)
            components.minute = Calendar.current.component(.minute, from: dueDate)
        }
        reminder.dueDateComponents = components
        
        // B-33：同步写入 EK priority——此前只写缓存，EK 侧提醒无优先级；
        // 语义映射：本项目 EventPriority 9=最高，EKReminder 1=最高、9=最低、0=无
        reminder.priority = Self.ekPriority(from: priority)
        
        // 设置提醒闹钟：多级 offsets 优先，单级 minutes 兼容；
        // 提醒路径传 due → 系统侧写准点绝对闹钟（提前提醒由应用内缓存承担）
        reminder.alarms = Self.makeAlarms(offsets: reminderOffsets, minutes: reminderMinutes, reminderDueDate: dueDate)
        
        try eventStore.save(reminder, commit: true)
        
        // 保存到本地缓存
        if let context = cacheService.context {
            let cached = CachedEvent(
                eventID: reminder.calendarItemIdentifier,
                title: reminder.title ?? "",
                startDate: dueDate,
                endDate: dueDate,
                isAllDay: isAllDay,
                calendarID: "reminder",
                calendarTitle: "提醒",
                calendarColorHex: reminder.calendar?.cgColor?.hexString ?? "#FF9500",
                category: .user,
                isReminder: true,
                isCompleted: false,
                priority: priority?.rawValue ?? 0,
                reminderMinutes: reminderMinutes ?? 0,
                eventColorHex: color?.rawValue,
                skipHolidays: skipHolidays
            )
            // 多级提醒：经 setter 写入以维护硬不变量 reminderMinutes == offsets.max()
            if let offsets = reminderOffsets, !offsets.isEmpty {
                cached.reminderOffsets = offsets
            }
            context.insert(cached)
            do {
                try context.save()
            } catch {
                AppLogger.sync.error("缓存同步失败: \(String(describing: error))")
            }
        }
    }

    /// 创建循环任务单条系统日历事件（单条化 plan step 4：去组参数）
    @MainActor
    private func createCalendarEventWithGroupInfo(
        title: String,
        startDate: Date,
        endDate: Date?,
        isAllDay: Bool,
        calendar: EKCalendar?,
        priority: EventPriority? = nil,
        reminderMinutes: Int? = nil,
        reminderOffsets: [Int]? = nil,
        category: EventCategory,
        recurrenceType: RecurrenceType,
        isLunar: Bool,
        color: EventColor? = nil,
        skipHolidays: Bool = false,
        validity: ValidityPeriod? = nil
    ) throws {
        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = startDate
        // 全天事件的结束日期必须是第二天，否则EventKit会报错
        if isAllDay {
            event.endDate = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: startDate)) ?? startDate.addingTimeInterval(86400)
        } else {
            let calculatedEndDate = endDate ?? startDate.addingTimeInterval(3600)
            // 确保 endDate > startDate
            if calculatedEndDate <= startDate {
                event.endDate = startDate.addingTimeInterval(3600)
            } else {
                event.endDate = calculatedEndDate
            }
        }
        event.isAllDay = isAllDay
        let targetCalendar = calendar ?? eventStore.defaultCalendarForNewEvents ?? calendars.first
        event.calendar = targetCalendar

        // 设置提醒（仅当用户指定时才添加）：多级 offsets 优先，单级 minutes 兼容
        event.alarms = Self.makeAlarms(offsets: reminderOffsets, minutes: reminderMinutes)

        guard event.calendar != nil else {
            throw EventError.noCalendarAvailable
        }

        // B-5：与 createCalendarEvent 一致，用户分类事件统一打来源标记，
        // 避免清缓存重同步后被误归为 .system 而遭连带删除
        if category == .user {
            event.notes = "此事项来自SwallowCalendar应用"
        }

        try eventStore.save(event, span: .thisEvent)

        // 保存到本地缓存（单条化：无组概念，完成历史与 startDate 推进由 toggleEventCompleted 维护）
        if let context = cacheService.context {
            let cached = CachedEvent(
                eventID: event.eventIdentifier,
                title: event.title ?? "",
                startDate: event.startDate,
                endDate: event.endDate,
                isAllDay: event.isAllDay,
                calendarID: event.calendar.calendarIdentifier,
                calendarTitle: event.calendar.title,
                calendarColorHex: event.calendar.cgColor?.hexString ?? "#007AFF",
                category: category,
                priority: priority?.rawValue ?? 0,
                recurrenceType: recurrenceType,
                isLunar: isLunar,
                reminderMinutes: reminderMinutes ?? 0,
                eventColorHex: color?.rawValue,
                skipHolidays: skipHolidays,
                // 有效期归一化落库（spec AC-6，plan step 6）：nil = 该端不限制
                validStartDate: validity?.normalizedStartDate,
                validEndDate: validity?.normalizedEndDate
            )
            // 多级提醒：经 setter 写入以维护硬不变量 reminderMinutes == offsets.max()
            if let offsets = reminderOffsets, !offsets.isEmpty {
                cached.reminderOffsets = offsets
            }
            // 历史锚点 = 创建时刻的序列首实例（bug: recurring-past-occurrence-invisible）：
            // 已过时刻被推进时本值即下一期，与「每天跑步从明天起」语义一致
            cached.originStartDate = cached.startDate
            context.insert(cached)
            do {
                try context.save()
            } catch {
                AppLogger.sync.error("缓存同步失败: \(String(describing: error))")
            }
        }
    }

    /// 创建循环任务单条系统提醒（单条化 plan step 4：去组参数）
    @MainActor
    private func createReminderWithGroupInfo(
        title: String,
        dueDate: Date,
        isAllDay: Bool,
        priority: EventPriority? = nil,
        recurrenceType: RecurrenceType,
        isLunar: Bool,
        reminderMinutes: Int? = nil,
        reminderOffsets: [Int]? = nil,
        color: EventColor? = nil,
        skipHolidays: Bool = false,
        validity: ValidityPeriod? = nil
    ) throws {
        guard reminderAuthorizationStatus == .fullAccess else {
            throw EventError.noReminderAccess
        }

        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = title
        reminder.calendar = eventStore.defaultCalendarForNewReminders() ?? eventStore.calendars(for: .reminder).first
        guard reminder.calendar != nil else {
            throw EventError.noReminderCalendarAvailable
        }

        // 设置到期时间
        var components = Calendar.current.dateComponents([.year, .month, .day], from: dueDate)
        if !isAllDay {
            components.hour = Calendar.current.component(.hour, from: dueDate)
            components.minute = Calendar.current.component(.minute, from: dueDate)
        }
        reminder.dueDateComponents = components

        // 设置提醒闹钟：多级 offsets 优先，单级 minutes 兼容；
        // 提醒路径传 due → 系统侧写准点绝对闹钟（提前提醒由应用内缓存承担）
        reminder.alarms = Self.makeAlarms(offsets: reminderOffsets, minutes: reminderMinutes, reminderDueDate: dueDate)

        try eventStore.save(reminder, commit: true)

        // 保存到本地缓存（单条化：无组概念，完成历史与 startDate 推进由 toggleEventCompleted 维护）
        if let context = cacheService.context {
            let cached = CachedEvent(
                eventID: reminder.calendarItemIdentifier,
                title: reminder.title ?? "",
                startDate: dueDate,
                endDate: dueDate,
                isAllDay: isAllDay,
                calendarID: "reminder",
                calendarTitle: "提醒",
                calendarColorHex: reminder.calendar?.cgColor?.hexString ?? "#FF9500",
                category: .user,
                isReminder: true,
                isCompleted: false,
                priority: priority?.rawValue ?? 0,
                recurrenceType: recurrenceType,
                isLunar: isLunar,
                reminderMinutes: reminderMinutes ?? 0,
                eventColorHex: color?.rawValue,
                skipHolidays: skipHolidays,
                // 有效期归一化落库（spec AC-6，plan step 6）：nil = 该端不限制
                validStartDate: validity?.normalizedStartDate,
                validEndDate: validity?.normalizedEndDate
            )
            // 多级提醒：经 setter 写入以维护硬不变量 reminderMinutes == offsets.max()
            if let offsets = reminderOffsets, !offsets.isEmpty {
                cached.reminderOffsets = offsets
            }
            // 历史锚点 = 创建时刻的序列首实例（同 createCalendarEventWithGroupInfo）
            cached.originStartDate = cached.startDate
            context.insert(cached)
            do {
                try context.save()
            } catch {
                AppLogger.sync.error("缓存同步失败: \(String(describing: error))")
            }
        }
    }

    /// 删除事件（日历事件或提醒）
    @MainActor
    func deleteEvent(eventID: String, isReminder: Bool = false) throws {
        // 单条化 plan step 8：列表行可能是 occurrence 虚拟展开行（复合 ID），
        // 删循环任务 = 删整条，回查本体 ID（Risks 表 Mitigation：删除入口先 parseOccurrenceID 分流）
        let baseID = CachedEvent.parseOccurrenceID(eventID)?.baseID ?? eventID
        // B-7：EK 对象缺失（已被外部删除等）不再直接 return——仍继续删除缓存，
        // 避免幽灵条目；对象存在才走 EK 删除
        if isReminder {
            if let reminder = eventStore.calendarItem(withIdentifier: baseID) as? EKReminder {
                try eventStore.remove(reminder, commit: true)
            } else {
                AppLogger.sync.warning("deleteEvent EKReminder NOT-FOUND，仅删缓存 id=\(baseID)")
            }
        } else {
            if let event = eventStore.event(withIdentifier: baseID) {
                try eventStore.remove(event, span: .thisEvent)
            } else {
                AppLogger.sync.warning("deleteEvent EKEvent NOT-FOUND，仅删缓存 id=\(baseID)")
            }
        }
        
        // 从本地缓存删除
        if let cached = findCachedEvent(eventID: baseID) {
            cacheService.context?.delete(cached)
            do {
                try cacheService.context?.save()
            } catch {
                // B-7：缓存删除失败必须记日志，空 catch 静默吞错无法排查
                AppLogger.sync.error("deleteEvent 缓存删除失败: \(String(describing: error))")
            }
        }
    }

    /// 删除 EK 侧单条记录（EKEvent/EKReminder），供存量迁移使用（单条化 plan step 9）
    /// 与 deleteEvent 兜底语义一致：对象不存在（已被外部删除/无授权）视为已删除返回 true；
    /// remove 抛错记日志返回 false（调用方该组原地保留下次重试）
    @MainActor
    func deleteEKRecordIfExists(eventID: String, isReminder: Bool) -> Bool {
        do {
            if isReminder {
                if let reminder = eventStore.calendarItem(withIdentifier: eventID) as? EKReminder {
                    try eventStore.remove(reminder, commit: true)
                }
            } else {
                if let event = eventStore.event(withIdentifier: eventID) {
                    try eventStore.remove(event, span: .thisEvent)
                }
            }
            return true
        } catch {
            AppLogger.sync.error("迁移删除 EK 记录失败 id=\(eventID, privacy: .public): \(String(describing: error))")
            return false
        }
    }
    
    /// 确保 EKEvent 的 notes 中带有完成标记（自愈历史已办）
    /// - Note: 历史已办（[SC_COMPLETED] 机制引入前标记完成）的系统日历事件 notes 中没有标记，
    ///         同步时若缓存已完成而 EK 无标记，调用此方法补写标记，让系统日历成为完成状态的真源，
    ///         此后清缓存/换设备重新同步也能从系统日历恢复完成状态。
    /// - Returns: 是否补写成功（事件不存在或保存失败返回 false，但缓存已完成状态不受影响；
    ///            失败已在本方法内打日志，当前唯一调用方（同步自愈补写）仅关心副作用无需检查，
    ///            故标记 @discardableResult 消除未使用返回值警告，保留未来调用方检查能力）
    @MainActor
    @discardableResult
    func ensureCompletedMarker(for eventID: String) -> Bool {
        let completedMarker = "[SC_COMPLETED]"
        guard let event = eventStore.event(withIdentifier: eventID) else {
            AppLogger.sync.warning("ensureCompletedMarker EKEvent NOT-FOUND id=\(eventID)")
            return false
        }
        // 已有标记则无需补写
        if let notes = event.notes, notes.contains(completedMarker) {
            return true
        }
        if let notes = event.notes {
            event.notes = notes + " " + completedMarker
        } else {
            event.notes = completedMarker
        }
        do {
            try eventStore.save(event, span: .thisEvent)
            AppLogger.sync.info("ensureCompletedMarker 补写完成标记 id=\(eventID)")
            return true
        } catch {
            AppLogger.sync.error("ensureCompletedMarker 补写失败 id=\(eventID) err=\(String(describing: error))")
            return false
        }
    }

    /// 标记事件完成/未完成
    /// - Note: 对于系统提醒，会同步更新到系统提醒应用
    /// - Note: 对于系统日历事件，在 EKEvent 的 notes 中追加完成标记以持久化状态；
    ///         同步时会恢复 notes 中标记为已完成的事件状态
    /// - Note: 循环任务 occurrence（复合 ID）分流到 toggleRecurringOccurrence：
    ///         完成只记录历史并推进 startDate，不再整条标记、不再追加实例
    @MainActor
    func toggleEventCompleted(eventID: String, isCompleted: Bool, isReminder: Bool = false) async {
        // 单条化 plan step 5：复合 occurrence ID 分流。本体行查不到复合 ID，
        // 幂等守卫与 EK 查询对其均无效，必须最先分流
        if let parts = CachedEvent.parseOccurrenceID(eventID) {
            await toggleRecurringOccurrence(
                baseID: parts.baseID,
                occurrence: parts.occurrence,
                isCompleted: isCompleted,
                isReminder: isReminder
            )
            return
        }

        // 幂等守卫：目标状态与缓存一致时跳过全部写入。防止“弹窗单条完成 + 全部完成”
        // 双重完成路径对同一周期事项重复追加实例（审查 P1：完成分支缺少状态检查）
        if let cached = findCachedEvent(eventID: eventID), cached.isCompleted == isCompleted {
            AppLogger.sync.debug("完成状态未变化，跳过写入 id=\(eventID) completed=\(isCompleted)")
            return
        }

        // B-2：跟踪 EK 写入是否失败（对象不存在不算失败——无旧状态可翻转）
        var ekSaveFailed = false

        if isReminder {
            // 使用 if let 而非 guard，确保即使 EventKit 中找不到该提醒，
            // 本地缓存仍能正常更新（已完成提醒可能无法通过 calendarItem 获取）
            if let reminder = eventStore.calendarItem(withIdentifier: eventID) as? EKReminder {
                reminder.isCompleted = isCompleted
                do {
                    try eventStore.save(reminder, commit: true)
                    AppLogger.sync.debug("EKReminder save ok id=\(eventID) completed=\(isCompleted)")
                } catch {
                    ekSaveFailed = true
                    AppLogger.sync.error("EKReminder save FAILED id=\(eventID) completed=\(isCompleted) err=\(String(describing: error))")
                }
            } else {
                AppLogger.sync.warning("EKReminder calendarItem NOT-FOUND 尝试兜底查询 id=\(eventID) completed=\(isCompleted)")
                // 兜底：calendarItem 对已完成的 iCloud 提醒可能返回 nil，
                // 此时若只更新缓存，重启后 syncReminders 会从 EK 拉到旧的未完成状态，
                // 导致已完成事项再次弹窗。改用全量查询找到后补写 EK，保证两端一致。
                if let reminder = await fetchReminderObject(byID: eventID) {
                    reminder.isCompleted = isCompleted
                    do {
                        try eventStore.save(reminder, commit: true)
                        AppLogger.sync.info("EKReminder save ok(fallback) id=\(eventID) completed=\(isCompleted)")
                    } catch {
                        ekSaveFailed = true
                        AppLogger.sync.error("EKReminder save FAILED(fallback) id=\(eventID) err=\(String(describing: error))")
                    }
                } else {
                    // 兜底仍未找到：事项多半已从 EventKit 删除，syncReminders 会同步删除缓存记录
                    AppLogger.sync.warning("EKReminder fallback NOT-FOUND 事项可能已删除 id=\(eventID)")
                }
            }
        } else {
            // 日历事件：在 EKEvent 的 notes 中追加完成标记，确保同步后能恢复完成状态
            if let event = eventStore.event(withIdentifier: eventID) {
                let completedMarker = "[SC_COMPLETED]"
                if isCompleted {
                    // 追加完成标记（避免重复添加）
                    if let notes = event.notes, !notes.contains(completedMarker) {
                        event.notes = notes + " " + completedMarker
                    } else if event.notes == nil {
                        event.notes = completedMarker
                    }
                } else {
                    // 移除完成标记
                    if let notes = event.notes {
                        event.notes = notes.replacingOccurrences(of: " " + completedMarker, with: "")
                            .replacingOccurrences(of: completedMarker, with: "")
                    }
                }
                do {
                    try eventStore.save(event, span: .thisEvent)
                    AppLogger.sync.debug("EKEvent save ok id=\(eventID) completed=\(isCompleted)")
                } catch {
                    ekSaveFailed = true
                    AppLogger.sync.error("EKEvent save FAILED id=\(eventID) completed=\(isCompleted) err=\(String(describing: error))")
                }
            } else {
                AppLogger.sync.warning("EKEvent NOT-FOUND EventKit未收到完成状态 id=\(eventID) completed=\(isCompleted)")
            }
        }
        
        // B-2：EK 保存失败时终止——不更新缓存完成状态、不追加周期实例，
        // 避免下次同步从 EK 拉回旧状态导致完成状态翻转、周期实例膨胀
        if ekSaveFailed {
            AppLogger.sync.warning("EK写入失败，已跳过缓存更新与周期追加 id=\(eventID) completed=\(isCompleted)")
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "同步失败"
            alert.informativeText = "完成状态写入系统日历/提醒失败，本次修改未生效，请稍后重试。"
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        // 更新本地缓存
        if let cached = findCachedEvent(eventID: eventID) {
            cached.isCompleted = isCompleted
            do {
                try cacheService.context?.save()
            } catch {
                AppLogger.sync.error("更新缓存失败: \(String(describing: error))")
            }
        }
    }

    /// 循环任务 occurrence 级完成/撤销（单条化 plan step 5）
    /// - 本体单条 + completedOccurrenceDates 完成历史 + startDate 推进式序列
    /// - EK 侧不打 [SC_COMPLETED]：完成时平移 EK startDate/endDate（提醒为 dueDateComponents）到下一次 occurrence
    /// - 幂等依据：occurrence 是否已在完成历史
    /// - 撤销：仅移除历史日期，EK 与 startDate 不回退（序列推进事实不可逆）
    @MainActor
    private func toggleRecurringOccurrence(baseID: String, occurrence: Date, isCompleted: Bool, isReminder: Bool) async {
        guard let cached = findCachedEvent(eventID: baseID), cached.recurrenceType != .none else {
            AppLogger.sync.warning("循环 occurrence 本体不存在或已非循环 base=\(baseID)")
            return
        }

        // occurrence 级幂等：目标状态与完成历史一致时跳过全部写入
        let alreadyDone = cached.completedOccurrenceDates.contains { $0 == occurrence }
        if alreadyDone == isCompleted {
            AppLogger.sync.debug("occurrence 完成状态未变化，跳过 base=\(baseID) completed=\(isCompleted)")
            return
        }

        if isCompleted {
            // 推进判定：next 为 nil 表示序列终止或冻结；occurrence 早于 startDate 属历史补完成，只记历史不推进
            var next = CalendarService.nextOccurrence(
                after: occurrence,
                recurrenceType: cached.recurrenceType,
                isLunar: cached.isLunar
            )
            // 有效期补齐（spec/task-validity-period AC-5，plan step 5b）：startDate 落后于
            // 有效期开始端（编辑把开始端改到未来产生空档）时，逐周期推进到首个 ≥ validStart
            if let validStart = cached.validStartDate {
                var catchup = 0
                while let t = next, t < validStart, catchup < 4000 {
                    next = CalendarService.nextOccurrence(
                        after: t,
                        recurrenceType: cached.recurrenceType,
                        isLunar: cached.isLunar
                    )
                    catchup += 1
                }
                if catchup >= 4000 {
                    AppLogger.sync.error("有效期补齐达迭代上限，中止推进 base=\(baseID)")
                    next = nil
                }
            }
            // 有效期冻结（spec/task-validity-period AC-4，plan step 5c）：下一次 occurrence 越过
            // 结束端 → 停止出现，next 置 nil：不写 EK 不动 startDate，仅记完成历史
            if let validEnd = cached.validEndDate, let t = next, t > validEnd {
                AppLogger.sync.debug("occurrence 越过有效期结束端，冻结推进 base=\(baseID)")
                next = nil
            }
            let shouldAdvance = next != nil && occurrence >= (cached.startDate ?? occurrence)

            var ekSaveFailed = false
            if shouldAdvance {
                if isReminder {
                    // EKReminder：dueDateComponents 推进到下一次 occurrence（全天不含时分，与创建逻辑一致）
                    if let reminder = eventStore.calendarItem(withIdentifier: baseID) as? EKReminder, let next {
                        var components = Calendar.current.dateComponents([.year, .month, .day], from: next)
                        if !cached.isAllDay {
                            components.hour = Calendar.current.component(.hour, from: next)
                            components.minute = Calendar.current.component(.minute, from: next)
                        }
                        reminder.dueDateComponents = components
                        do {
                            try eventStore.save(reminder, commit: true)
                            AppLogger.sync.debug("EKReminder occurrence 推进 ok base=\(baseID)")
                        } catch {
                            ekSaveFailed = true
                            AppLogger.sync.error("EKReminder occurrence 推进失败 base=\(baseID) err=\(String(describing: error))")
                        }
                    } else {
                        AppLogger.sync.warning("EKReminder NOT-FOUND 跳过 occurrence 推进 base=\(baseID)")
                    }
                } else {
                    // EKEvent：非全天沿用原时长平移（全天 startDate 即当日 00:00，时长平移等价日界）
                    if let ekEvent = eventStore.event(withIdentifier: baseID), let next {
                        let originalStart = cached.startDate ?? occurrence
                        let originalEnd = cached.endDate ?? originalStart
                        ekEvent.startDate = next
                        ekEvent.endDate = next.addingTimeInterval(originalEnd.timeIntervalSince(originalStart))
                        do {
                            try eventStore.save(ekEvent, span: .thisEvent)
                            AppLogger.sync.debug("EKEvent occurrence 推进 ok base=\(baseID)")
                        } catch {
                            ekSaveFailed = true
                            AppLogger.sync.error("EKEvent occurrence 推进失败 base=\(baseID) err=\(String(describing: error))")
                        }
                    } else {
                        AppLogger.sync.warning("EKEvent NOT-FOUND 跳过 occurrence 推进 base=\(baseID)")
                    }
                }
            }

            if ekSaveFailed {
                // 与主路径一致：EK 写失败不更新缓存，避免下次同步从 EK 拉回旧状态导致状态翻转
                AppLogger.sync.warning("EK写入失败，已跳过循环 occurrence 缓存更新 base=\(baseID) completed=\(isCompleted)")
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "同步失败"
                alert.informativeText = "完成状态写入系统日历/提醒失败，本次修改未生效，请稍后重试。"
                alert.alertStyle = .warning
                alert.runModal()
                return
            }

            // 缓存侧：追加完成历史；推进时 startDate/endDate 平移保持时长，isCompleted 保持 false
            var history = cached.completedOccurrenceDates
            history.append(occurrence)
            cached.completedOccurrenceDates = history

            if shouldAdvance, let next {
                let originalStart = cached.startDate ?? occurrence
                let originalEnd = cached.endDate ?? originalStart
                let duration = originalEnd.timeIntervalSince(originalStart)
                cached.startDate = next
                cached.endDate = next.addingTimeInterval(duration)
            }
        } else {
            // 撤销完成：仅移除历史日期（序列不回退）
            var history = cached.completedOccurrenceDates
            history.removeAll { $0 == occurrence }
            cached.completedOccurrenceDates = history
        }

        do {
            try cacheService.context?.save()
        } catch {
            AppLogger.sync.error("循环 occurrence 缓存更新失败 base=\(baseID): \(String(describing: error))")
        }
    }

    /// 更新事件（日历事件或提醒）
    /// - Parameter reminderOffsets: 多级提醒偏移数组；nil = 不改提醒，空数组 = 清除全部提醒
    /// - Parameter skipHolidays: nil = 不改跳过节假日标记（编辑面板未触碰该开关时保持原值）
    /// - Parameter validity: 有效期三态（spec/task-validity-period AC-6，plan step 7）：
    ///   外层 nil = 未触碰保持原值；内层 nil = 清除区间；.some(period) = 归一化落库
    @MainActor
    func updateEvent(eventID: String, title: String?, startDate: Date?, endDate: Date?, isAllDay: Bool? = nil, isReminder: Bool = false, priority: EventPriority? = nil, reminderMinutes: Int? = nil, reminderOffsets: [Int]? = nil, color: EventColor? = nil, skipHolidays: Bool? = nil, validity: ValidityPeriod?? = nil) throws {
        // 单条化 plan step 7：列表行可能是 occurrence 虚拟展开行（复合 ID），
        // 编辑即改整条，回查本体 ID（Risks 表 Mitigation：编辑入口先 parseOccurrenceID 分流）
        let baseID = CachedEvent.parseOccurrenceID(eventID)?.baseID ?? eventID
        if isReminder {
            guard let reminder = eventStore.calendarItem(withIdentifier: baseID) as? EKReminder else { return }
            if let title { reminder.title = title }
            // B-6：startDate 与 endDate 任一传入都更新到期时间（提醒只有 dueDate
            // 一个时间语义），原实现忽略 endDate 导致只调结束时间不生效
            if let dueSource = startDate ?? endDate {
                var components = Calendar.current.dateComponents([.year, .month, .day], from: dueSource)
                // 全天事件只写日期；非全天写入具体时间（isAllDay 未传时按原始时间
                // 是否带时分秒推断——B-22：原 <86400 判定会把跨天定时提醒
                //（如今天10:00~明天10:30，间隔>24h）误判为全天）
                let isTimed: Bool
                if let isAllDay {
                    isTimed = !isAllDay
                } else {
                    let comps = Calendar.current.dateComponents([.hour, .minute, .second], from: dueSource)
                    isTimed = (comps.hour ?? 0) != 0 || (comps.minute ?? 0) != 0 || (comps.second ?? 0) != 0
                }
                if isTimed {
                    components.hour = Calendar.current.component(.hour, from: dueSource)
                    components.minute = Calendar.current.component(.minute, from: dueSource)
                }
                reminder.dueDateComponents = components
            }
            // 更新提醒闹钟：多级 offsets 优先（空数组=清除），单级 minutes 兼容；
            // 两者均未传时不动 alarms（保持 nil = 不改提醒语义）；
            // 提醒路径传当前 due → 系统侧写准点绝对闹钟（提前提醒由应用内缓存承担）
            if reminderOffsets != nil || reminderMinutes != nil {
                reminder.alarms = Self.makeAlarms(offsets: reminderOffsets, minutes: reminderMinutes, reminderDueDate: reminder.dueDateComponents?.date)
            }
            try eventStore.save(reminder, commit: true)
        } else {
            guard let event = eventStore.event(withIdentifier: baseID) else { return }
            if let title { event.title = title }
            if let startDate { event.startDate = startDate }
            if let endDate { event.endDate = endDate }
            if let isAllDay { event.isAllDay = isAllDay }
            // E-6：切为全天时显式清 endDate——UI 全天保存传 endDate=nil，
            // 上面 if let 不执行会残留原截止时间；EK 全天单日惯例 endDate=startDate
            if let isAllDay, isAllDay {
                event.endDate = event.startDate
            }
            // 更新日历事件闹钟：多级 offsets 优先（空数组=清除），单级 minutes 兼容；
            // 两者均未传时不动 alarms（保持 nil = 不改提醒语义）
            if reminderOffsets != nil || reminderMinutes != nil {
                event.alarms = Self.makeAlarms(offsets: reminderOffsets, minutes: reminderMinutes)
            }
            try eventStore.save(event, span: .thisEvent)
        }

        // 更新本地缓存
        if let cached = findCachedEvent(eventID: baseID) {
            if let title { cached.title = title }
            if isReminder {
                // B-6：提醒只有到期时间一个语义，startDate==endDate 必须同步写，
                // 原实现只写 startDate、endDate 残留旧值导致缓存与 EK 分叉
                if let dueSource = startDate ?? endDate {
                    cached.startDate = dueSource
                    cached.endDate = dueSource
                }
            } else {
                if let startDate { cached.startDate = startDate }
                // E-6：切为全天时缓存 endDate 同步清为 startDate（零长全天单日），
                // 消除带时间→全天切换后的残留截止时间
                if let isAllDay, isAllDay {
                    cached.endDate = startDate ?? cached.startDate
                } else if let endDate {
                    cached.endDate = endDate
                }
            }
            // isAllDay 必须同步，否则"全天 ↔ 带时间"切换后缓存与 EK 不一致，UI 显示错误
            if let isAllDay { cached.isAllDay = isAllDay }
            if let priority { cached.priority = priority.rawValue }
            if let reminderOffsets {
                // 多级：经 setter 写入维护硬不变量（空数组=清除多级回退单级）
                cached.reminderOffsets = reminderOffsets
                if reminderOffsets.isEmpty {
                    // 清除提醒时单级归零，避免 includeExpired 分支按旧 max 误判"已设置提醒"
                    cached.reminderMinutes = 0
                }
            } else if let reminderMinutes {
                // G1：多级 JSON 可能已存在，直赋必须经显式方法反向重写最高档
                //（@Model 宏不保留 didSet，联动已显式化）
                cached.setReminderMinutesRewritingMax(reminderMinutes)
            }
            if let color { cached.eventColorHex = color.rawValue }
            // 跳过节假日标记：仅显式传入时写回（nil = 保持原值）
            if let skipHolidays { cached.skipHolidays = skipHolidays }
            // 有效期三态写入（spec AC-6，plan step 7）：validity 为 ValidityPeriod??，
            // 一层解包后内层 nil = 清除区间（链式取归一化得 nil），.some = 归一化落库
            if let validity {
                cached.validStartDate = validity?.normalizedStartDate
                cached.validEndDate = validity?.normalizedEndDate
            }
            cached.lastUpdated = Date()
            do {
                try cacheService.context?.save()
            } catch {
                // B-6：缓存保存失败记日志，try? 静默吞错无法排查
                AppLogger.sync.error("updateEvent 缓存保存失败: \(String(describing: error))")
            }
        }
    }
    
    /// 更新事件周期类型（单条化 plan step 7：编辑即改整条）
    /// - 周期→1次：清完成历史（普通任务只有 isCompleted 单状态），startDate 不动
    /// - 1次→周期 / 周期类型变更：仅更新类型，下一次 occurrence 由查询链从 startDate 以新周期推进
    @MainActor
    func updateEventRecurrence(eventID: String, newRecurrenceType: RecurrenceType) {
        // 列表行可能是 occurrence 虚拟展开行（复合 ID），编辑永远作用于本体记录
        let baseID = CachedEvent.parseOccurrenceID(eventID)?.baseID ?? eventID
        guard let context = cacheService.context,
              let cached = findCachedEvent(eventID: baseID) else {
            return
        }

        guard cached.recurrenceType != newRecurrenceType else { return }

        cached.recurrenceType = newRecurrenceType
        if newRecurrenceType == .none {
            cached.completedOccurrenceDatesJSON = nil
            // 切单次对称清除有效期（spec AC-6，plan step 8）：单次任务无周期语义，区间随之失效
            cached.validStartDate = nil
            cached.validEndDate = nil
        }

        do {
            try context.save()
        } catch {
            AppLogger.sync.error("updateEventRecurrence 缓存保存失败: \(String(describing: error))")
        }
    }

    // MARK: - Sync

    /// 根据 eventID 查找缓存事件
    @MainActor
    private func findCachedEvent(eventID: String) -> CachedEvent? {
        guard let context = cacheService.context else { return nil }
        var descriptor = FetchDescriptor<CachedEvent>(predicate: #Predicate { $0.eventID == eventID })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// 手动同步日历事件到本地缓存
    func manualSync(preferences: [CalendarPreference], completion: ((Bool, String) -> Void)? = nil) {
        guard authorizationStatus == .fullAccess else {
            completion?(false, "日历权限不足，请在系统设置中授权")
            return
        }

        let enabledCals = enabledCalendars(preferences: preferences)
        guard !enabledCals.isEmpty else {
            // 没有开启的日历，直接返回成功
            DispatchQueue.main.async {
                completion?(true, "同步成功")
            }
            return
        }

        Task {
            // B-28：取真实同步结果回传——原实现无条件回"同步成功"，
            // 保存失败时 UI 无法感知，用户误以为数据已同步
            let success = await cacheService.syncEvents(from: self, calendars: enabledCals)
            await MainActor.run {
                completion?(success, success ? "同步成功" : "同步失败，请重试")
            }
        }
    }

    // MARK: - Helpers

    /// 获取下一个农历日期
    /// - Note: 当前实现使用 Calendar(identifier: .chinese) 直接计算，对于农历闰月（如闰七月）的处理依赖于系统 Calendar 的实现。
    ///         在大多数情况下能正确工作，但在极端边界场景下可能需要额外验证。
    // internal 供测试 @testable 使用
    func getNextLunarDate(from date: Date, recurrenceType: RecurrenceType) -> Date? {
        let chineseCalendar = Calendar(identifier: .chinese)

        // B-17：改用 date(byAdding:) 由系统 Calendar 处理农历溢出——原组件加法
        // （month+1/day+30 后 date(from:)）在 29 天小月、无对应闰月时返回 nil，
        // 周期序列被截断；date(byAdding:) 对溢出做系统取整（如 30 日遇小月取月末），
        // 序列不再中断，闰月也按系统逐月推进语义处理
        switch recurrenceType {
        case .unlimited, .daily:
            return chineseCalendar.date(byAdding: .day, value: 1, to: date)
        case .weekly:
            return chineseCalendar.date(byAdding: .day, value: 7, to: date)
        case .monthly:
            return chineseCalendar.date(byAdding: .month, value: 1, to: date)
        case .yearly:
            return chineseCalendar.date(byAdding: .year, value: 1, to: date)
        default:
            return nil
        }
    }

    private func mapToCalendarEvent(_ ekEvent: EKEvent) -> CalendarEvent {
        // 系统日历同步的事件统一归为系统分类（不管日历类型是 calDAV 还是 subscription）
        let category: EventCategory = .system
        return CalendarEvent(
            id: ekEvent.eventIdentifier,
            title: ekEvent.title ?? "",
            startDate: ekEvent.startDate,
            endDate: ekEvent.endDate,
            isAllDay: ekEvent.isAllDay,
            calendarID: ekEvent.calendar.calendarIdentifier,
            calendarTitle: ekEvent.calendar.title,
            calendarColorHex: ekEvent.calendar.cgColor?.hexString ?? "#007AFF",
            category: category,
            isCompleted: false,
            priority: 0,  // 系统日历事件没有优先级
            isReminder: false,
            recurrenceType: .none,
            reminderMinutes: Self.extractReminderMinutes(from: ekEvent.alarms),
            reminderOffsets: Self.extractReminderOffsets(from: ekEvent.alarms),
            eventColorHex: nil,
            notes: ekEvent.notes
        )
    }

    private func cachedToCalendarEvent(_ cached: CachedEvent) -> CalendarEvent {
        return CalendarEvent(
            id: cached.eventID,
            title: cached.title,
            startDate: cached.startDate,
            endDate: cached.endDate,
            isAllDay: cached.isAllDay,
            calendarID: cached.calendarID,
            calendarTitle: cached.calendarTitle,
            calendarColorHex: cached.calendarColorHex,
            category: cached.category,
            isCompleted: cached.isCompleted,
            priority: cached.priority,
            isReminder: cached.isReminder,
            recurrenceType: cached.recurrenceType,
            reminderMinutes: cached.reminderMinutes,
            eventColorHex: cached.eventColorHex,
            skipHolidays: cached.skipHolidays,
            // 有效期透传（spec AC-6，plan step 9）：双字段已归一化，组装区间载体供 UI/服务层
            validity: (cached.validStartDate != nil || cached.validEndDate != nil)
                ? ValidityPeriod(start: cached.validStartDate, end: cached.validEndDate)
                : nil
        )
    }
    
    private func dayRange(for date: Date) -> (start: Date, end: Date) {
        let cal = Calendar.current
        let start = cal.startOfDay(for: date)
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        return (start, end)
    }
}

// MARK: - Event Error

enum EventError: LocalizedError {
    case noCalendarAvailable
    case noReminderAccess
    case noReminderCalendarAvailable

    var errorDescription: String? {
        switch self {
        case .noCalendarAvailable:
            return "没有可用的日历，请先在系统日历中创建一个日历账户"
        case .noReminderAccess:
            return "没有提醒权限，请在系统设置中授权访问提醒"
        case .noReminderCalendarAvailable:
            return "没有可用的提醒列表，请先在系统提醒中创建一个列表"
        }
    }
}

// MARK: - CGColor Extension

extension CGColor {
    var hexString: String {
        guard let components = components, components.count >= 3 else { return "#007AFF" }
        let r = Int(components[0] * 255)
        let g = Int(components[1] * 255)
        let b = Int(components[2] * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

// MARK: - Recurrence Helper

extension CalendarService {
    /// 确定性单步推进到下一个 occurrence（单条化 plan step 3）
    /// 与当前时间无关（供虚拟展开/完成推进共用，after 为未来日期也精确 +1 周期）；
    /// monthly 走 B-16 锚定日语义（31 日遇小月取月末且不漂移）；
    /// isLunar 走农历 Calendar(identifier: .chinese)（B-17 系统取整语义）；
    /// 跳过节假日不在此处理——语义 v3 为显示层静默过滤，不改写序列
    static func nextOccurrence(after date: Date, recurrenceType: RecurrenceType, isLunar: Bool) -> Date? {
        if isLunar {
            let chineseCalendar = Calendar(identifier: .chinese)
            switch recurrenceType {
            case .unlimited, .daily:
                return chineseCalendar.date(byAdding: .day, value: 1, to: date)
            case .weekly:
                return chineseCalendar.date(byAdding: .day, value: 7, to: date)
            case .monthly:
                return chineseCalendar.date(byAdding: .month, value: 1, to: date)
            case .yearly:
                return chineseCalendar.date(byAdding: .year, value: 1, to: date)
            case .hourly:
                // bug: hourly-recurrence-invisible-in-lists——与每天/每周同语义恢复展开+推进；
                // 无双份风险（锚条目法已过滤 Apple 物化的已完成历史）
                return chineseCalendar.date(byAdding: .hour, value: 1, to: date)
            case .none, .custom:
                return nil
            }
        }
        switch recurrenceType {
        case .unlimited, .daily:
            return Calendar.current.date(byAdding: .day, value: 1, to: date)
        case .weekly:
            return Calendar.current.date(byAdding: .weekOfYear, value: 1, to: date)
        case .monthly:
            // spec Edge cases 定案：月末由 Calendar.date(byAdding:) 系统取整，
            // 与 nextOccurrence 行为一致；展开链与完成推进链共用本函数保持自洽
            return Calendar.current.date(byAdding: .month, value: 1, to: date)
        case .yearly:
            return Calendar.current.date(byAdding: .year, value: 1, to: date)
        case .hourly:
            return Calendar.current.date(byAdding: .hour, value: 1, to: date)
        case .none, .custom:
            return nil
        }
    }

    /// nextOccurrence 的逆运算（反向单步，bug: recurring-past-occurrence-invisible）：
    /// 供存量循环行回填历史锚点时从游标反向回退；monthly 与正向同走 Calendar.date(byAdding:)
    /// 系统取整，正反共用取整语义保持序列自洽
    static func previousOccurrence(before date: Date, recurrenceType: RecurrenceType, isLunar: Bool) -> Date? {
        if isLunar {
            let chineseCalendar = Calendar(identifier: .chinese)
            switch recurrenceType {
            case .unlimited, .daily:
                return chineseCalendar.date(byAdding: .day, value: -1, to: date)
            case .weekly:
                return chineseCalendar.date(byAdding: .day, value: -7, to: date)
            case .monthly:
                return chineseCalendar.date(byAdding: .month, value: -1, to: date)
            case .yearly:
                return chineseCalendar.date(byAdding: .year, value: -1, to: date)
            case .hourly:
                // 与 nextOccurrence 对应（bug: hourly-recurrence-invisible-in-lists）
                return chineseCalendar.date(byAdding: .hour, value: -1, to: date)
            case .none, .custom:
                return nil
            }
        }
        switch recurrenceType {
        case .unlimited, .daily:
            return Calendar.current.date(byAdding: .day, value: -1, to: date)
        case .weekly:
            return Calendar.current.date(byAdding: .weekOfYear, value: -1, to: date)
        case .monthly:
            return Calendar.current.date(byAdding: .month, value: -1, to: date)
        case .yearly:
            return Calendar.current.date(byAdding: .year, value: -1, to: date)
        case .hourly:
            return Calendar.current.date(byAdding: .hour, value: -1, to: date)
        case .none, .custom:
            return nil
        }
    }

    /// 展开起点对齐（bug: reminder-starved-by-badge-expansion）：
    /// expandOccurrences 从锚点逐次推进到窗口的开销与锚点年龄成正比（31 年前锚点
    /// 的每天循环 = 1.1 万次无产出推进），状态栏徽章每秒展开把主线程占满，提醒
    /// 检查 Timer 被饿死——本函数用日历单位整除直接跳到「≤ windowStart 的最近
    /// 相位」，调用方回退一个周期后即可跳过全部无产出推进。
    /// 仅适用日加法族（daily/unlimited/weekly/hourly）：nextOccurrence 对该族用
    /// Calendar.date(byAdding: day/weekOfYear/hour) 单位加法，整除跳转与逐次推进产生
    /// 完全相同的相位序列（completedOccurrenceDates 的 epoch 精确匹配依赖此）；
    /// monthly/yearly 存在月末取整累积（1-31 逐次 +1 月与一次 +N 月结果不同）、
    /// 农历无固定数值周期——均返回 nil 保持逐次推进（其锚点年龄成本本就可忽略）。
    /// 锚点已贴近窗口（k < 1）或窗口早于锚点时返回 nil，调用方零变化回退
    static func alignedExpansionStart(origin: Date, recurrenceType: RecurrenceType, isLunar: Bool, windowStart: Date) -> Date? {
        guard !isLunar else { return nil }
        let calendar = Calendar.current
        switch recurrenceType {
        case .unlimited, .daily:
            let days = calendar.dateComponents([.day], from: origin, to: windowStart).day ?? 0
            guard days >= 1,
                  let aligned = calendar.date(byAdding: .day, value: days, to: origin),
                  aligned < windowStart else { return nil }
            return aligned
        case .weekly:
            // 周期数按天数差整除计算，跳转与 nextOccurrence 同用 .weekOfYear 加法保持同源
            let weeks = (calendar.dateComponents([.day], from: origin, to: windowStart).day ?? 0) / 7
            guard weeks >= 1,
                  let aligned = calendar.date(byAdding: .weekOfYear, value: weeks, to: origin),
                  aligned < windowStart else { return nil }
            return aligned
        case .hourly:
            // bug: hourly-recurrence-invisible-in-lists——小时加法无取整累积，
            // 整除跳转与 nextOccurrence 同用 .hour 加法保持同源
            let hours = calendar.dateComponents([.hour], from: origin, to: windowStart).hour ?? 0
            guard hours >= 1,
                  let aligned = calendar.date(byAdding: .hour, value: hours, to: origin),
                  aligned < windowStart else { return nil }
            return aligned
        case .none, .custom, .monthly, .yearly:
            return nil
        }
    }

    /// 存量循环行回填历史锚点 originStartDate（bug: recurring-past-occurrence-invisible）
    /// 算法：从游标反向单步回退，取不早于创建时刻的第一个序列点——游标即创建时
    /// 推进/落定的序列首实例，反向链上每点均为合法周期点，时刻模式自动对齐；
    /// 下界用创建时刻（而非创建日零点），保留「创建时已过时刻推进到下一期」的
    /// 首实例语义（不补出创建日已过实例）。EK 无创建时间或游标早于创建时刻（异常）
    /// 返回 nil，保持游标展开回退
    static func resolveOriginStartDate(cursor: Date, creationDate: Date?, recurrenceType: RecurrenceType, isLunar: Bool) -> Date? {
        guard let creation = creationDate, cursor >= creation else { return nil }
        var occ = cursor
        var iterations = 0
        while let prev = previousOccurrence(before: occ, recurrenceType: recurrenceType, isLunar: isLunar), prev >= creation {
            occ = prev
            iterations += 1
            if iterations >= 4000 {
                AppLogger.sync.error("历史锚点回填达迭代上限，中止 base cursor=\(cursor, privacy: .public)")
                break
            }
        }
        return occ
    }

    /// EK 侧创建时间（存量循环行回填 originStartDate 用，bug: recurring-past-occurrence-invisible）
    /// EventCacheService 同步路径无 eventStore，经本访问器读取；查不到返回 nil
    func ekCreationDate(eventID: String, isReminder: Bool) -> Date? {
        if isReminder {
            return (eventStore.calendarItem(withIdentifier: eventID) as? EKReminder)?.creationDate
        }
        return eventStore.event(withIdentifier: eventID)?.creationDate
    }

    /// 将日期推进到下一个周期，确保结果 > 当前时间
    /// - Parameters:
    ///   - date: 原始日期
    ///   - recurrenceType: 周期类型
    /// - Returns: 推进后的日期（保证 > Date()）
    static func advanceRecurrenceDate(_ date: Date, recurrenceType: RecurrenceType) -> Date {
        let now = Date()

        // 如果日期已经在未来，直接返回
        guard date <= now else { return date }

        var currentDate = date

        // B-16：迭代护栏——多年前的一次性 daily 日期原会逐日 while 推进上千次，
        // 超限（约 10 年）直接返回当前时间兜底
        let maxIterations = 3660
        var iterations = 0
        // B-16：monthly 锚定日——date(byAdding: .month) 遇 31 日→小月会截断到月末，
        // 连续推进后锚点漂移（1/31→2/28→3/28），改按锚定日逐月构造
        let anchorDay = Calendar.current.component(.day, from: date)

        // 循环推进直到时间在未来
        while currentDate <= now {
            if iterations >= maxIterations {
                return now
            }
            iterations += 1
            switch recurrenceType {
            case .unlimited, .daily:
                currentDate = Calendar.current.date(byAdding: .day, value: 1, to: currentDate) ?? currentDate
            case .weekly:
                currentDate = Calendar.current.date(byAdding: .weekOfYear, value: 1, to: currentDate) ?? currentDate
            case .monthly:
                currentDate = nextAnchoredMonthlyDate(from: currentDate, anchorDay: anchorDay) ?? currentDate
            case .yearly:
                currentDate = Calendar.current.date(byAdding: .year, value: 1, to: currentDate) ?? currentDate
            case .none, .custom, .hourly:
                // B-32：无推进语义，直接返回避免 while 死循环（date <= now 时循环条件恒真）
                return currentDate
            }
        }

        return currentDate
    }

    /// B-16：按锚定日推进到下一月的对应日期（锚定日超出该月天数时取月末）
    private static func nextAnchoredMonthlyDate(from date: Date, anchorDay: Int) -> Date? {
        let calendar = Calendar.current
        var comps = calendar.dateComponents([.year, .month], from: date)
        // 先落到当月 1 日：Calendar.date(from:) 对溢出 day 会滚动到下月（如 2 月 day=31
        // 产出 3 月 3 日且 non-nil），不能直接设 day=anchorDay
        comps.day = 1
        guard let first = calendar.date(from: comps),
              // 推进到下一月 1 日：本函数职责是"推进到下一月"，缺这步会返回同月锚定日，
              // advanceRecurrenceDate 的 while 循环输入输出恒等 → 死循环耗尽护栏
              let nextFirst = calendar.date(byAdding: .month, value: 1, to: first),
              let daysInMonth = calendar.range(of: .day, in: .month, for: nextFirst)?.count else {
            return nil
        }
        // 锚定日超出目标月天数（如 31 日遇 2 月）→ clamp 到该月最后一天
        var nextComps = calendar.dateComponents([.year, .month], from: nextFirst)
        nextComps.day = min(anchorDay, daysInMonth)
        // 保留原时间的时分秒：与原 date(byAdding: .month) 语义一致，否则重复事项时间归零
        nextComps.hour = calendar.component(.hour, from: date)
        nextComps.minute = calendar.component(.minute, from: date)
        nextComps.second = calendar.component(.second, from: date)
        return calendar.date(from: nextComps)
    }
}
