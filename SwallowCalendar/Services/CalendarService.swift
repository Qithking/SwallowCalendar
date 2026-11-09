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
    /// 测试注入：抑制「同步失败」模态弹窗（生产默认 false，避免单测被 runModal 阻塞）
    var suppressesSyncFailureAlert = false
    var calendars: [EKCalendar] = []

    /// 事件缓存服务
    let cacheService = EventCacheService.shared

    /// EKEventStore.changed 监听 token（随实例存活；单例常驻，应用退出即终止，无需注销）
    private var externalStoreChangeObservers: [NSObjectProtocol] = []

    // internal 供测试 @testable 使用
    init() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        reminderAuthorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
        startObservingExternalStoreChanges()
    }

    // MARK: - 外部变更监听

    /// 外部 app 对日历/提醒的新建、修改、完成、删除会 post EKEventStoreChanged，
    /// 转发给后台同步服务做防抖同步（reminder-sync-completeness）
    /// - Note: macOS 无 scoped 通知中心 API（EKEventStore.notificationCenter(for:) 仅 iOS），
    ///         变更通知统一投递 default center
    private func startObservingExternalStoreChanges() {
        externalStoreChangeObservers.append(
            NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                // EK 通知可能后台线程投递，跳主线程再进入防抖
                Task { @MainActor [weak self] in
                    // 仅需确认服务仍存活（后续只调用共享单例，不再使用 self）
                    guard self != nil else { return }
                    AppLogger.sync.info("EKEventStore.changed → 触发外部变更同步")
                    BackgroundSyncService.shared.syncOnExternalChange()
                }
            }
        )
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

    /// 启动/开关路径是否需要主动请求提醒权限（reminder-auth-prompt）
    /// 仅当用户已开启提醒同步且权限处于 notDetermined（从未询问）时需要；
    /// denied 由启动引导弹窗与设置页「前往设置」承接，fullAccess/writeOnly/restricted 无需请求
    static func shouldRequestReminderAccess(syncEnabled: Bool, reminderAuth: EKAuthorizationStatus) -> Bool {
        syncEnabled && reminderAuth == .notDetermined
    }

    /// 单独请求提醒 fullAccess（reminder-auth-prompt）
    /// - Note: 日历已授权而提醒 notDetermined 时，原 requestAccess 仅随日历授权入口触发，
    ///         该状态会永久卡死（同步条件 == .fullAccess 永不满足），需独立请求入口
    @MainActor
    func requestReminderAccess() async -> Bool {
        do {
            let result = try await eventStore.requestFullAccessToReminders()
            reminderAuthorizationStatus = result ? .fullAccess : .denied
            return result
        } catch {
            reminderAuthorizationStatus = .denied
            return false
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
        // 农历镜像（notes 带镜像标记）不进缓存/展示：应用内仍由 base 农历展开承担，
        // 系统侧镜像只是一条普通事件，避免重复出现或反写 base 农历规则
        return ekEvents
            .filter { LunarMirrorPlan.occurrenceID(from: $0.notes) == nil }
            .map { mapToCalendarEvent($0) }
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

    // MARK: - Reminders

    /// 获取系统提醒（待办事项）
    /// - Parameters:
    ///   - includeCompleted: 是否包含已完成的提醒，默认 false
    ///   - from: 可选的开始日期，用于过滤有到期时间的提醒
    ///   - to: 可选的结束日期，用于过滤有到期时间的提醒
    /// - Note: 没有到期时间的提醒不受日期范围限制，始终返回
    /// - Returns: nil 表示获取失败（授权丢失/EK 调用失败），空数组才是真实无数据；
    ///           调用方（syncReminders 差集删除）必须区分二者，失败时禁止清空缓存
    func fetchReminders(includeCompleted: Bool = false, from: Date? = nil, to: Date? = nil) async -> [CalendarEvent]? {
        // R-4：授权丢失原与"真空"同返 []，下游差集删除会误清全部提醒缓存
        //（completedOccurrenceDatesJSON/originStartDate 仅存缓存，丢失不可恢复）
        guard reminderAuthorizationStatus == .fullAccess else {
            return nil
        }

        let predicate = eventStore.predicateForReminders(in: nil)

        return await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                // R-4：EK 回调 nil = XPC 失败，同样与"真空"区分
                guard let all = reminders else {
                    continuation.resume(returning: nil)
                    return
                }
                // 农历镜像（notes 带镜像标记）不进缓存：应用内展示仍由 base 农历展开承担，
                // 系统侧镜像只是一条普通提醒，避免在应用内重复出现/反写 base 规则
                let visible = all.filter { LunarMirrorPlan.occurrenceID(from: $0.notes) == nil }
                // bug: ek-recurrence-materialization-mirror——Apple 对循环提醒按「发生」物化为
                // 独立 EKReminder，历史发生以已完成态落库。锚集合 = 带规则的未完成条目，
                // 同 title 已完成条目即物化历史，不入库（syncReminders 按返回集差集自动删缓存）
                let anchorTitles = Set(
                    visible.filter { !$0.isCompleted && !($0.recurrenceRules ?? []).isEmpty }
                           .compactMap { $0.title }
                )
                // 同 title 已完成历史到期序列：EK 无 hourly 表达（每小时/每天均 daily），
                // 借物化历史间隔推断真实档位
                let historyDueDates = Self.completedDueDatesByTitle(from: visible)
                let mappedReminders = visible.compactMap { reminder -> CalendarEvent? in
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
        let inferredType = Self.mapRecurrenceRule(
            reminder.recurrenceRules?.first,
            historyDueDates: historyDueDates
        )
        // 规则→spec 是反向同步唯一入口（外部改 interval/星期/结束条件据此回流）
        let spec = RecurrenceEKMapper.spec(
            from: reminder.recurrenceRules?.first,
            anchor: dueDate ?? reminder.dueDateComponents?.date ?? Date(),
            inferredType: inferredType
        )
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
            recurrenceType: inferredType,
            recurrenceSpec: spec,
            reminderMinutes: Self.extractReminderMinutes(from: reminder.alarms),
            reminderOffsets: Self.extractReminderOffsets(from: reminder.alarms),
            // absolute 准点闹钟（任务 E 模式）标记：sync 回流时保留缓存提前提醒
            reminderAlarmIsAbsolute: Self.hasAbsoluteReminderAlarm(reminder.alarms),
            eventColorHex: nil,
            // 本地循环标记随 notes 透传：merge 回流据此区分「应用内设循环」与「外部删规则」
            notes: reminder.notes
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

    /// 从 EKAlarm 数组提取最早（最大）提前分钟数；无有效相对闹钟返回 0
    private static func extractReminderMinutes(from alarms: [EKAlarm]?) -> Int {
        extractReminderOffsets(from: alarms)?.max() ?? 0
    }

    /// 从 EKAlarm 数组提取完整提醒偏移数组（多级，plan 步骤 7）
    /// 有符号分钟：正=提前、0=到点、负=延后；absolute 闹钟不携带提前量；
    /// 去重升序；无有效 alarm 返回 nil（无提前提醒）
    static func extractReminderOffsets(from alarms: [EKAlarm]?) -> [Int]? {
        guard let alarms else { return nil }
        let offsets = Set(alarms.compactMap { alarm -> Int? in
            // macOS 上 absolute 闹钟 relativeOffset 呈现为 0，必须按 absoluteDate 排除
            guard alarm.absoluteDate == nil else { return nil }
            let minutes = Int((-alarm.relativeOffset / 60).rounded())
            guard abs(minutes) <= CachedEvent.maxReminderLeadMinutes else { return nil }
            return minutes
        }).sorted()
        return offsets.isEmpty ? nil : offsets
    }

    /// EK 闹钟数组是否含 absolute（绝对时刻）闹钟（兼容 Apple 原生提醒模式）
    /// - Note: 判据为 absoluteDate 非 nil；macOS 上 absolute 闹钟的 relativeOffset
    ///   呈现为 0 而非 nil（ReminderAlarmAbsoluteTests 实证），不可用 relativeOffset 判定
    static func hasAbsoluteReminderAlarm(_ alarms: [EKAlarm]?) -> Bool {
        alarms?.contains { $0.absoluteDate != nil } ?? false
    }

    /// 生成 EKAlarm 数组（方案 B，执行文档 2026-10-28 用户确认，2026-11-07 重申）
    /// - 提醒路径（reminderDueDate 非空）：设置了提前提醒（多级或单级）→ 系统侧仅写
    ///   `absolute(due)` 准点闹钟，提醒事项 App 显示准点；提前提醒由应用内缓存
    ///   reminderOffsets 承担（ReminderAlertService 按 due-offset 提前弹窗）
    /// - 事件路径（reminderDueDate 为空）：逐档写 `relativeOffset`，系统日历通知按提前量触发
    /// - 偏移符号：正=提前（relativeOffset 为负）、0=到点、负=延后（relativeOffset 为正）
    static func makeAlarms(offsets: [Int]?, minutes: Int?, reminderDueDate: Date? = nil) -> [EKAlarm] {
        if let due = reminderDueDate {
            if offsets?.isEmpty == false || (minutes ?? 0) != 0 {
                return [EKAlarm(absoluteDate: due)]
            }
            return []
        }
        let resolved: [Int]
        if let offsets, !offsets.isEmpty {
            resolved = CachedEvent.normalizedReminderOffsets(offsets)
        } else if let minutes, minutes != 0 {
            resolved = CachedEvent.normalizedReminderOffsets([minutes])
        } else {
            resolved = []
        }
        return resolved.map { EKAlarm(relativeOffset: TimeInterval(-$0 * 60)) }
    }

    /// 构造 EKReminder.dueDateComponents（全部写回点唯一入口）
    /// - Note: bug advance-recurrence-missing-timezone——Calendar.current.dateComponents(_:from:)
    ///   返回值 timeZone 为 nil（探针实证），带 recurrenceRules 的循环提醒写回无时区 dueDate 后，
    ///   ReminderKit 推进前向警报报 Fault「dueDate missing timezone」；显式补 Calendar 时区
    static func makeDueComponents(from date: Date, isAllDay: Bool) -> DateComponents {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        if !isAllDay {
            components.hour = Calendar.current.component(.hour, from: date)
            components.minute = Calendar.current.component(.minute, from: date)
        }
        components.timeZone = Calendar.current.timeZone
        return components
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
        recurrenceSpec: RecurrenceSpec? = nil,
        reminderMinutes: Int? = nil,
        reminderOffsets: [Int]? = nil,
        category: EventCategory = .system,
        asReminder: Bool = false,
        isLunar: Bool = false,
        color: EventColor? = nil,
        skipHolidays: Bool = false,
        validity: ValidityPeriod? = nil
    ) throws {
        // spec 为真源；未显式传入时按旧档位 + 起始日推导（存量调用零变化）
        let spec = recurrenceSpec ?? RecurrenceSpec.legacy(from: recurrence ?? .none, anchor: startDate, isLunar: isLunar)
        let recurrenceType = spec?.legacyType ?? .none

        // 周期任务需要确保时间在当前时间之后（多选星期/每月日期不匹配时首期先顺延）
        var finalStartDate = startDate
        var finalEndDate = endDate
        if let spec {
            finalStartDate = spec.firstOccurrence(from: startDate, isLunar: isLunar) ?? startDate
            // E-4：全天事件的 startDate=当日 00:00，恒早于 Date()，
            // 会把当天创建的"每天"全天事项首实例错误推进到明天；
            // 全天只需早于今天零点才算已过期，带时间保持 <= 当前时刻
            let isOverdue = isAllDay
                ? finalStartDate < Calendar.current.startOfDay(for: Date())
                : finalStartDate <= Date()
            if isOverdue {
                finalStartDate = CalendarService.advanceRecurrenceDate(
                    finalStartDate,
                    spec: spec,
                    isLunar: isLunar
                )
                // 同时推进 endDate（如果有）
                if let ed = endDate {
                    let timeDiff = ed.timeIntervalSince(startDate)
                    finalEndDate = finalStartDate.addingTimeInterval(timeDiff)
                }
            }
        }

        // 循环任务：单条创建（spec 写入缓存；提醒同时写入 EK 规则，每小时/农历仅本地）
        if spec != nil {
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
                    recurrenceSpec: spec,
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
                    recurrenceSpec: spec,
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
            // EK 无小时频度：每小时仅在应用内承载，不写系统规则（原实现会误降级为「每天」）
            let freq: EKRecurrenceFrequency?
            switch recurrence {
            case .daily, .unlimited: freq = .daily
            case .weekly: freq = .weekly
            case .monthly: freq = .monthly
            case .yearly: freq = .yearly
            case .none, .custom: freq = .daily
            case .hourly: freq = nil
            }
            if let freq {
                let rule = EKRecurrenceRule(recurrenceWith: freq, interval: 1, end: nil)
                event.addRecurrenceRule(rule)
            }
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
            event.notes = CachedEvent.userOriginMarker
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
        
        // 设置到期时间（统一入口，保证 dueDateComponents 携带时区）
        reminder.dueDateComponents = Self.makeDueComponents(from: dueDate, isAllDay: isAllDay)
        
        // B-33：同步写入 EK priority——此前只写缓存，EK 侧提醒无优先级；
        // 语义映射：本项目 EventPriority 9=最高，EKReminder 1=最高、9=最低、0=无
        reminder.priority = Self.ekPriority(from: priority)
        
        // 设置提醒闹钟：多级 offsets 优先，单级 minutes 兼容；
        // 提醒路径传 due → 系统侧写准点绝对闹钟（方案 B，提前提醒由应用内缓存承担）
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
        recurrenceSpec: RecurrenceSpec? = nil,
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
            event.notes = CachedEvent.userOriginMarker
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
                recurrenceSpecJSON: recurrenceSpec?.jsonString,
                reminderMinutes: reminderMinutes ?? 0,
                eventColorHex: color?.rawValue,
                skipHolidays: skipHolidays,
                // 有效期归一化落库（spec AC-6，plan step 6）：nil = 该端不限制
                validStartDate: validity?.start,
                validEndDate: validity?.end
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

        // 农历：把未来期次写成普通日历事件镜像（当前期由本体承担；仅每月/每年启用）
        if LunarMirrorPolicy.isMirrorEnabled(isLunar: isLunar, spec: recurrenceSpec),
           let baseID = event.eventIdentifier {
            Task { @MainActor [weak self] in
                await self?.reconcileLunarMirrors(baseID: baseID)
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
        recurrenceSpec: RecurrenceSpec? = nil,
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

        // 设置到期时间（统一入口，保证 dueDateComponents 携带时区）
        reminder.dueDateComponents = Self.makeDueComponents(from: dueDate, isAllDay: isAllDay)

        // 设置提醒闹钟：多级 offsets 优先，单级 minutes 兼容；
        // 提醒路径传 due → 系统侧写准点绝对闹钟（方案 B，提前提醒由应用内缓存承担）
        reminder.alarms = Self.makeAlarms(offsets: reminderOffsets, minutes: reminderMinutes, reminderDueDate: dueDate)

        // 正向映射唯一入口：可表达档位写 EK 规则；每小时/农历仅本地，打标记供回流保留
        if let spec = recurrenceSpec {
            if let rule = RecurrenceEKMapper.rule(for: spec, anchor: dueDate, isLunar: isLunar) {
                reminder.addRecurrenceRule(rule)
            } else {
                reminder.notes = Self.appendingLocalMarker(to: reminder.notes)
            }
        }

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
                recurrenceSpecJSON: recurrenceSpec?.jsonString,
                reminderMinutes: reminderMinutes ?? 0,
                eventColorHex: color?.rawValue,
                skipHolidays: skipHolidays,
                // 有效期归一化落库（spec AC-6，plan step 6）：nil = 该端不限制
                validStartDate: validity?.start,
                validEndDate: validity?.end
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

        // 农历：把未来期次写成普通提醒镜像（当前期由本体承担；仅每月/每年启用）
        if LunarMirrorPolicy.isMirrorEnabled(isLunar: isLunar, spec: recurrenceSpec) {
            let baseID = reminder.calendarItemIdentifier
            Task { @MainActor [weak self] in
                await self?.reconcileLunarMirrors(baseID: baseID)
            }
        }
    }

    /// 删除事件（日历事件或提醒）
    @MainActor
    func deleteEvent(eventID: String, isReminder: Bool = false) throws {
        // 单条化 plan step 8：列表行可能是 occurrence 虚拟展开行（复合 ID），
        // 删循环任务 = 删整条，回查本体 ID（Risks 表 Mitigation：删除入口先 parseOccurrenceID 分流）
        let baseID = CachedEvent.parseOccurrenceID(eventID)?.baseID ?? eventID
        // 删除前取缓存类型：删完后需要判断是否清理农历镜像（日历事件与提醒都要覆盖）
        let cachedBeforeDelete = findCachedEvent(eventID: baseID)
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
        if let cached = cachedBeforeDelete {
            cacheService.context?.delete(cached)
            do {
                try cacheService.context?.save()
            } catch {
                // B-7：缓存删除失败必须记日志，空 catch 静默吞错无法排查
                AppLogger.sync.error("deleteEvent 缓存删除失败: \(String(describing: error))")
            }
        }

        // 农历镜像：删 base 同步清理未来未完成镜像，已完成/已过期保留
        let hadMirrors = cachedBeforeDelete?.isLunar == true
            || !(cachedBeforeDelete?.mirrorKeys.isEmpty ?? true)
            || !(cachedBeforeDelete?.suppressedMirrorKeys.isEmpty ?? true)
        if isReminder || hadMirrors {
            let deletedBaseID = baseID
            Task { @MainActor [weak self] in
                await self?.deleteLunarMirrors(baseID: deletedBaseID, isReminder: isReminder)
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
        let completedMarker = CachedEvent.completedMarker
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
                let completedMarker = CachedEvent.completedMarker
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
            presentSyncFailureAlert(text: "完成状态写入系统日历/提醒失败，本次修改未生效，请稍后重试。")
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

        // 完成推进统一走 spec：间隔/多选星期/第 N 个周几/结束条件均按同一真源计算
        guard let spec = cached.recurrenceSpec else {
            AppLogger.sync.warning("循环 occurrence 缺少 spec，跳过推进 base=\(baseID)")
            return
        }
        let sequenceOrigin = cached.originStartDate ?? cached.startDate ?? occurrence

        if isCompleted {
            // 推进判定：next 为 nil 表示序列终止或冻结；occurrence 早于 startDate 属历史补完成，只记历史不推进
            var next = spec.next(after: occurrence, origin: sequenceOrigin, isLunar: cached.isLunar)
            // 有效期补齐（spec/task-validity-period AC-5，plan step 5b）：startDate 落后于
            // 有效期开始端（编辑把开始端改到未来产生空档）时，逐周期推进到首个 ≥ validStart
            if let validStart = cached.validStartDate {
                var catchup = 0
                while let t = next, t < validStart, catchup < 4000 {
                    next = spec.next(after: t, origin: sequenceOrigin, isLunar: cached.isLunar)
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
            // BUG-09：对应域名已授权时 NOT-FOUND 等价于「外部已删除」，必须按写失败中止缓存推进，
            // 否则 EK 保留旧日期、缓存单边推进，下次同步会把游标拉回造成分叉；
            // 无授权（含测试宿主）时 EK 求值为空，保持「对象不存在不算失败」既有语义
            let ekReachable = isReminder
                ? reminderAuthorizationStatus == .fullAccess
                : authorizationStatus == .fullAccess
            if shouldAdvance {
                if isReminder {
                    // EKReminder：dueDateComponents 推进到下一次 occurrence（全天不含时分，与创建逻辑一致）
                    if let reminder = eventStore.calendarItem(withIdentifier: baseID) as? EKReminder, let next {
                        reminder.dueDateComponents = Self.makeDueComponents(from: next, isAllDay: cached.isAllDay)
                        do {
                            try eventStore.save(reminder, commit: true)
                            AppLogger.sync.debug("EKReminder occurrence 推进 ok base=\(baseID)")
                        } catch {
                            ekSaveFailed = true
                            AppLogger.sync.error("EKReminder occurrence 推进失败 base=\(baseID) err=\(String(describing: error))")
                        }
                    } else {
                        AppLogger.sync.warning("EKReminder NOT-FOUND 跳过 occurrence 推进 base=\(baseID)")
                        // BUG-09：已授权却查不到 = 外部删除，按写失败处理避免缓存单边推进
                        if ekReachable { ekSaveFailed = true }
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
                        // BUG-09：同上，已授权却查不到 = 外部删除
                        if ekReachable { ekSaveFailed = true }
                    }
                }
            }

            if ekSaveFailed {
                // 与主路径一致：EK 写失败不更新缓存，避免下次同步从 EK 拉回旧状态导致状态翻转
                AppLogger.sync.warning("EK写入失败，已跳过循环 occurrence 缓存更新 base=\(baseID) completed=\(isCompleted)")
                presentSyncFailureAlert(text: "完成状态写入系统日历/提醒失败，本次修改未生效，请稍后重试。")
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

        // 农历镜像：完成推进后，本体已承担新当前期 → 删除冗余镜像；已完成历史镜像标记完成并保留
        if needsLunarMirrorReconcile(cached) {
            await reconcileLunarMirrors(baseID: baseID)
        }
    }

    /// 同步失败模态提示；测试可经 suppressesSyncFailureAlert 抑制，避免 runModal 阻塞
    private func presentSyncFailureAlert(text: String) {
        guard !suppressesSyncFailureAlert else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "同步失败"
        alert.informativeText = text
        alert.alertStyle = .warning
        alert.runModal()
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
        // BUG-06：编辑展开实例（复合 ID）时不允许改时间——startDate/endDate/isAllDay 会写回
        // EK base 并回拨整条序列游标；此处统一丢弃时间类参数，仅保留标题/优先级/提醒/颜色等
        let isOccurrenceInstance = CachedEvent.parseOccurrenceID(eventID) != nil
        if isOccurrenceInstance, startDate != nil || endDate != nil || isAllDay != nil {
            AppLogger.ui.warning("updateEvent 展开实例忽略时间修改 id=\(eventID)（需作用于整条系列）")
        }
        let effectiveStartDate = isOccurrenceInstance ? nil : startDate
        let effectiveEndDate = isOccurrenceInstance ? nil : endDate
        let effectiveIsAllDay = isOccurrenceInstance ? nil : isAllDay
        if isReminder {
            // R-5：EK 对象失效（事项可能已被系统侧删除）时静默跳过会令 UI 假装保存成功，
            // 补 NOT-FOUND 日志（对照 deleteEvent B-7）；缓存分支同步跳过——否则下次同步
            // 会从 EK 拉回旧状态覆盖（同 B-2 一致性原则）
            guard let reminder = eventStore.calendarItem(withIdentifier: baseID) as? EKReminder else {
                AppLogger.sync.warning("updateEvent EKReminder NOT-FOUND，跳过更新 id=\(baseID)")
                return
            }
            if let title { reminder.title = title }
            // B-6：startDate 与 endDate 任一传入都更新到期时间（提醒只有 dueDate
            // 一个时间语义），原实现忽略 endDate 导致只调结束时间不生效
            if let dueSource = effectiveStartDate ?? effectiveEndDate {
                // 全天事件只写日期；非全天写入具体时间（isAllDay 未传时按原始时间
                // 是否带时分秒推断——B-22：原 <86400 判定会把跨天定时提醒
                //（如今天10:00~明天10:30，间隔>24h）误判为全天）
                let isTimed: Bool
                if let effectiveIsAllDay {
                    isTimed = !effectiveIsAllDay
                } else {
                    let comps = Calendar.current.dateComponents([.hour, .minute, .second], from: dueSource)
                    isTimed = (comps.hour ?? 0) != 0 || (comps.minute ?? 0) != 0 || (comps.second ?? 0) != 0
                }
                reminder.dueDateComponents = Self.makeDueComponents(from: dueSource, isAllDay: !isTimed)
            }
            // 更新提醒闹钟：多级 offsets 优先（空数组=清除），单级 minutes 兼容；
            // 两者均未传时不动 alarms（保持 nil = 不改提醒语义）；
            // 提醒路径传当前 due → 系统侧写准点绝对闹钟（方案 B，提前提醒由应用内缓存承担）
            if reminderOffsets != nil || reminderMinutes != nil {
                reminder.alarms = Self.makeAlarms(offsets: reminderOffsets, minutes: reminderMinutes, reminderDueDate: reminder.dueDateComponents?.date)
            }
            try eventStore.save(reminder, commit: true)
        } else {
            // R-5：同上，EKEvent 对象失效时补 NOT-FOUND 日志
            guard let event = eventStore.event(withIdentifier: baseID) else {
                AppLogger.sync.warning("updateEvent EKEvent NOT-FOUND，跳过更新 id=\(baseID)")
                return
            }
            let wasAllDay = event.isAllDay
            if let title { event.title = title }
            if let effectiveStartDate { event.startDate = effectiveStartDate }
            if let effectiveEndDate {
                event.endDate = effectiveEndDate
            } else if let effectiveIsAllDay, effectiveIsAllDay, !wasAllDay {
                // E-6：带时间 → 全天，无原始时长可保，按单日处理
                event.endDate = event.startDate
            }
            // 已是全天且未传 endDate：保留原 endDate（用户未改日期时不改写 23:59:59 等原值）
            if let effectiveIsAllDay { event.isAllDay = effectiveIsAllDay }
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
                if let dueSource = effectiveStartDate ?? effectiveEndDate {
                    cached.startDate = dueSource
                    cached.endDate = dueSource
                }
            } else {
                let wasCachedAllDay = cached.isAllDay
                if let effectiveStartDate { cached.startDate = effectiveStartDate }
                if let effectiveEndDate {
                    cached.endDate = effectiveEndDate
                } else if let effectiveIsAllDay, effectiveIsAllDay, !wasCachedAllDay {
                    // E-6：带时间 → 全天，缓存 endDate 同步为单日
                    cached.endDate = effectiveStartDate ?? cached.startDate
                }
                // 已是全天且未传 endDate：保留原缓存 endDate（与 EK 侧一致）
            }
            // isAllDay 必须同步，否则"全天 ↔ 带时间"切换后缓存与 EK 不一致，UI 显示错误
            if let effectiveIsAllDay { cached.isAllDay = effectiveIsAllDay }
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
            // 一层解包后内层 nil = 清除区间；.some = 原样落库（保留时分，不再按天归一化）
            if let validity {
                cached.validStartDate = validity?.start
                cached.validEndDate = validity?.end
            }
            cached.lastUpdated = Date()
            do {
                try cacheService.context?.save()
            } catch {
                // B-6：缓存保存失败记日志，try? 静默吞错无法排查
                AppLogger.sync.error("updateEvent 缓存保存失败: \(String(describing: error))")
            }

            // 农历镜像：标题/时间/提醒/有效期变更后对账（时间变更按新键重建未来镜像）
            if needsLunarMirrorReconcile(cached) {
                Task { @MainActor [weak self] in
                    await self?.reconcileLunarMirrors(baseID: baseID)
                }
            }
        }
    }
    
    /// 循环规则更新失败：必须让保存链路感知，不得静默当成「已保存」（审计 M3）
    enum RecurrenceUpdateError: LocalizedError {
        case cacheContextUnavailable
        case eventNotFound(String)

        var errorDescription: String? {
            switch self {
            case .cacheContextUnavailable:
                return "本地缓存尚未就绪，循环规则未保存"
            case .eventNotFound(let id):
                return "未找到要更新的事项（\(id)），循环规则未保存"
            }
        }
    }

    /// 更新事件周期类型（单条化 plan step 7：编辑即改整条）
    /// - 周期→1次（BUG-21 用户口径）：保留已完成历史（已办列表可见），清未来展开依据；
    ///   `completedOccurrenceDatesJSON` 不再清空，`originStartDate` 置 nil 防止从远古锚点
    ///   展开出过去未完成行；游标 startDate 不动
    /// - 1次→周期 / 周期类型变更：仅更新类型，下一次 occurrence 由查询链从 startDate 以新周期推进
    /// - Throws: 缓存上下文缺失、本体不存在或查询失败（M3：调用方须反馈给用户）
    @MainActor
    func updateEventRecurrence(eventID: String, newRecurrenceType: RecurrenceType) throws {
        let baseID = CachedEvent.parseOccurrenceID(eventID)?.baseID ?? eventID
        guard let cached = try findCachedEventOrThrow(eventID: baseID) else {
            throw RecurrenceUpdateError.eventNotFound(baseID)
        }
        let spec = RecurrenceSpec.legacy(
            from: newRecurrenceType,
            anchor: cached.originStartDate ?? cached.startDate ?? Date(),
            isLunar: cached.isLunar
        )
        try updateEventRecurrence(eventID: baseID, newSpec: spec)
    }

    /// 更新循环规则（spec 真源）：本地缓存 + 提醒 EK 规则双向落定
    /// - Parameter newIsLunar: 农历开关目标值；nil 表示沿用现值。
    ///   取消农历时 spec 可能与原值相等，必须靠该参数放行清理（否则未来镜像不会删）
    /// - 周期→1次：保留已完成历史，清未来展开依据与有效期
    /// - 每小时/农历：EK 无表达，不写规则并打本地标记（系统侧显示「永不」）
    /// - Throws: 缓存上下文缺失、本体不存在或查询/落库失败（M3：调用方须反馈给用户）
    @MainActor
    func updateEventRecurrence(eventID: String, newSpec: RecurrenceSpec?, newIsLunar: Bool? = nil) throws {
        // 列表行可能是 occurrence 虚拟展开行（复合 ID），编辑永远作用于本体记录
        let baseID = CachedEvent.parseOccurrenceID(eventID)?.baseID ?? eventID
        guard let context = cacheService.context else {
            throw RecurrenceUpdateError.cacheContextUnavailable
        }
        guard let cached = try findCachedEventOrThrow(eventID: baseID) else {
            throw RecurrenceUpdateError.eventNotFound(baseID)
        }

        let effectiveLunar = newIsLunar ?? cached.isLunar
        // 幂等防回环：规则与农历开关都未变才直接返回；
        // 取消农历时 spec 可能相等，不能只看 spec
        guard cached.recurrenceSpec != newSpec || cached.isLunar != effectiveLunar else { return }

        // 用户主动改规则/农历：解除系统侧手删抑制，允许按新规则重新铺设镜像
        cached.suppressedMirrorKeys = []

        cached.recurrenceSpec = newSpec
        cached.recurrenceType = newSpec?.legacyType ?? .none
        cached.isLunar = effectiveLunar
        if newSpec == nil {
            // 清未来展开依据：originStartDate 仅用于展开序列起点，留着会让 ② 从锚点产出历史未完成行
            cached.originStartDate = nil
            // 切单次对称清除有效期（spec AC-6，plan step 8）：单次任务无周期语义，区间随之失效
            cached.validStartDate = nil
            cached.validEndDate = nil
        } else {
            if cached.originStartDate == nil { cached.originStartDate = cached.startDate }
            // 多选星期/每月日期与起始日不匹配：首期顺延到最近匹配日（按目标农历口径对齐）
            if let spec = newSpec, let start = cached.startDate,
               let aligned = spec.firstOccurrence(from: start, isLunar: effectiveLunar),
               aligned != start {
                cached.startDate = aligned
                cached.endDate = cached.endDate.map { $0.addingTimeInterval(aligned.timeIntervalSince(start)) }
            }
        }

        do {
            try context.save()
        } catch {
            AppLogger.sync.error("updateEventRecurrence 缓存保存失败: \(String(describing: error))")
            // M3：落库失败必须让调用方感知，不得静默成功
            throw error
        }

        // 提醒行同步 EK 规则（可表达档位写规则；每小时/农历打标记；改单次清规则）
        if cached.isReminder {
            applyRecurrenceSpecToReminder(cached, spec: newSpec)
        }

        // 农历镜像：规则变更重建未来期次；改单次/取消农历清理未来未完成镜像
        if needsLunarMirrorReconcile(cached) {
            // 先取标量再起 Task：Task 跨 await 执行时模型可能已被释放/重置
            let baseID = cached.eventID
            Task { @MainActor [weak self] in
                await self?.reconcileLunarMirrors(baseID: baseID)
            }
        }
    }

    /// 提醒 EK 规则落定：正向映射唯一入口调用点（创建/编辑共用）
    @MainActor
    private func applyRecurrenceSpecToReminder(_ cached: CachedEvent, spec: RecurrenceSpec?) {
        guard let reminder = eventStore.calendarItem(withIdentifier: cached.eventID) as? EKReminder else { return }
        // 先清空全部旧规则（改回单次/改档位都走替换语义）
        for rule in reminder.recurrenceRules ?? [] {
            reminder.removeRecurrenceRule(rule)
        }
        let anchor = reminder.dueDateComponents?.date ?? cached.startDate ?? Date()
        if let spec, let rule = RecurrenceEKMapper.rule(for: spec, anchor: anchor, isLunar: cached.isLunar) {
            reminder.addRecurrenceRule(rule)
            reminder.notes = Self.removingLocalMarker(from: reminder.notes)
        } else if spec != nil {
            reminder.notes = Self.appendingLocalMarker(to: reminder.notes)
        } else {
            reminder.notes = Self.removingLocalMarker(from: reminder.notes)
        }
        // 编辑后 EK 到期时间跟随本地首期（多选星期/月末跳过顺延）
        if let start = cached.startDate {
            reminder.dueDateComponents = Self.makeDueComponents(from: start, isAllDay: cached.isAllDay)
        }
        do {
            try eventStore.save(reminder, commit: true)
        } catch {
            AppLogger.sync.error("EK 循环规则写入失败: \(String(describing: error))")
        }
    }

    /// 追加/移除本地循环标记（每小时/农历仅本地生效的识别依据）
    static func appendingLocalMarker(to notes: String?) -> String {
        let marker = EventCacheService.localRecurrenceMarker
        let current = notes ?? ""
        guard !current.contains(marker) else { return current }
        return current.isEmpty ? marker : "\(current) \(marker)"
    }

    static func removingLocalMarker(from notes: String?) -> String? {
        guard let notes else { return nil }
        let cleaned = notes
            .replacingOccurrences(of: EventCacheService.localRecurrenceMarker, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    // MARK: - 农历镜像（提醒 + 日历事件：每条期次一条普通、不循环记录）

    /// 同一 base 的对账串行化：并发触发时合并为一次重跑，避免重复创建镜像
    private var lunarMirrorInFlight: Set<String> = []
    private var lunarMirrorPending: Set<String> = []
    /// 批量补窗本轮拉取到的 EK 对象（仅 MainActor 同步使用，不跨 await 传递）
    private var lunarMirrorPrefetchedItems: [String: [String: EKCalendarItem]] = [:]

    /// 是否需要对账镜像：农历开关、登记/抑制键残留（覆盖取消农历后的清理路径）
    private func needsLunarMirrorReconcile(_ cached: CachedEvent) -> Bool {
        cached.isLunar
            || !cached.mirrorKeys.isEmpty
            || !cached.suppressedMirrorKeys.isEmpty
            // S5：损坏数据也要进对账（走跳过分支并留日志），不能当成「无需处理」
            || cached.recurrenceSpecState.isCorrupt
            || cached.mirrorKeysCorrupt
            || cached.suppressedMirrorKeysCorrupt
    }

    /// 对账某条农历 base 的系统镜像：补齐缺失、删除冗余、标记已完成历史。
    /// - Note: 镜像不进本地缓存，应用内展示仍由 base 农历展开承担；notes 标记为识别唯一依据。
    @MainActor
    func reconcileLunarMirrors(baseID: String) async {
        await reconcileLunarMirrors(baseID: baseID, prefetched: nil)
    }

    /// - Parameter prefetched: 批量补窗的一次拉取分组；仅首轮使用，重跑时置 nil 重新拉取，
    ///   避免用过期快照重复创建镜像
    @MainActor
    private func reconcileLunarMirrors(baseID: String, prefetched: PrefetchedLunarMirrorGroup?) async {
        guard !lunarMirrorInFlight.contains(baseID) else {
            lunarMirrorPending.insert(baseID)
            return
        }
        lunarMirrorInFlight.insert(baseID)
        // 异常/取消路径也必须清理在飞标记，否则该 base 后续对账全部被跳过
        defer { lunarMirrorInFlight.remove(baseID) }
        var firstPass = prefetched
        repeat {
            lunarMirrorPending.remove(baseID)
            await performLunarMirrorReconcile(baseID: baseID, prefetched: firstPass)
            firstPass = nil
        } while lunarMirrorPending.contains(baseID)
    }

    /// 批量补窗的 base 值类型快照：跨 await 只持有值类型，不再访问 SwiftData 模型（M-3）
    struct LunarMirrorBaseSnapshot: Equatable {
        let baseID: String
        let isReminder: Bool
        let needsReconcile: Bool
        let specState: SpecState
        /// 抑制列表损坏：本轮跳过重建（不能把损坏当成空列表）
        let suppressedKeysUnavailable: Bool

        /// 预筛（M-1）：仅「农历 + monthly/yearly」可产生镜像；
        /// 仍有登记/抑制残留、规则或登记损坏的必须对账（覆盖清理与诊断路径）
        init(
            baseID: String,
            isReminder: Bool,
            specState: SpecState,
            isLunar: Bool,
            hasRegistry: Bool,
            registryCorrupt: Bool = false,
            suppressedKeysUnavailable: Bool = false
        ) {
            self.baseID = baseID
            self.isReminder = isReminder
            self.specState = specState
            self.suppressedKeysUnavailable = suppressedKeysUnavailable
            self.needsReconcile = hasRegistry
                || registryCorrupt
                || suppressedKeysUnavailable
                || specState.isCorrupt
                || LunarMirrorPolicy.isMirrorEnabled(isLunar: isLunar, spec: specState.spec)
        }
    }

    /// 一次性收成值类型快照（调用点必须在任何 await 之前）
    static func makeLunarMirrorSnapshots(from cached: [CachedEvent]) -> [LunarMirrorBaseSnapshot] {
        cached.map { cachedEvent in
            LunarMirrorBaseSnapshot(
                baseID: cachedEvent.eventID,
                isReminder: cachedEvent.isReminder,
                specState: cachedEvent.recurrenceSpecState,
                isLunar: cachedEvent.isLunar,
                hasRegistry: !cachedEvent.mirrorKeys.isEmpty || !cachedEvent.suppressedMirrorKeys.isEmpty,
                registryCorrupt: cachedEvent.mirrorKeysCorrupt,
                suppressedKeysUnavailable: cachedEvent.suppressedMirrorKeysCorrupt
            )
        }
    }

    /// 单个 base 预取的镜像集合：只带值快照，可跨 await 传递
    struct PrefetchedLunarMirrorGroup: Sendable, Equatable {
        var existing: [ExistingLunarMirror] = []
    }

    /// 一次拉取的分组结果：`groups` 为 Sendable 值快照；`items` 是本轮 MainActor 内
    /// 删除/更新要用的 EK 对象，只同步使用，不随 await 传递
    struct MirrorGrouping {
        var groups: [String: PrefetchedLunarMirrorGroup] = [:]
        var items: [String: [String: EKCalendarItem]] = [:]
    }

    /// 按 baseID 分组提醒镜像；非镜像条目忽略（一次拉取，避免逐 base 全量扫描）
    static func groupReminderMirrors(_ reminders: [EKReminder]) -> MirrorGrouping {
        var grouping = MirrorGrouping()
        for reminder in reminders {
            guard let key = LunarMirrorPlan.occurrenceID(from: reminder.notes),
                  let parsed = CachedEvent.parseOccurrenceID(key) else { continue }
            grouping.groups[parsed.baseID, default: PrefetchedLunarMirrorGroup()].existing.append(ExistingLunarMirror(
                occurrenceID: key,
                date: parsed.occurrence,
                isCompleted: reminder.isCompleted,
                contentFingerprint: LunarMirrorPlan.contentFingerprint(from: reminder.notes)
            ))
            grouping.items[parsed.baseID, default: [:]][key] = reminder
        }
        return grouping
    }

    /// 按 baseID 分组日历镜像；非镜像条目忽略
    static func groupEventMirrors(_ events: [EKEvent]) -> MirrorGrouping {
        var grouping = MirrorGrouping()
        for event in events {
            guard let key = LunarMirrorPlan.occurrenceID(from: event.notes),
                  let parsed = CachedEvent.parseOccurrenceID(key) else { continue }
            grouping.groups[parsed.baseID, default: PrefetchedLunarMirrorGroup()].existing.append(ExistingLunarMirror(
                occurrenceID: key,
                date: parsed.occurrence,
                // 日历事件没有完成态：历史镜像只按是否过期保留
                isCompleted: false,
                contentFingerprint: LunarMirrorPlan.contentFingerprint(from: event.notes)
            ))
            grouping.items[parsed.baseID, default: [:]][key] = event
        }
        return grouping
    }

    /// 系统侧存在性集合：由已成功拉取的全量列表构建（H-1）。
    /// - Note: 不用 `calendarItem(withIdentifier:)` 单点查询——已完成/iCloud 提醒可能返回 nil，
    ///   会把系统侧仍存在的本体误判为孤儿
    static func systemBaseIDs(reminders: [EKReminder]) -> Set<String> {
        Set(reminders.map(\.calendarItemIdentifier))
    }

    static func systemBaseIDs(events: [EKEvent]) -> Set<String> {
        Set(events.compactMap(\.eventIdentifier))
    }

    /// 批量补窗（M8）：启动与每日一次调用。
    /// - 预筛：只为「可产生镜像（农历 + monthly/yearly）或有登记/抑制残留」的 base 对账（M-1）；
    /// - 预取：提醒 / 日历窗口各拉取一次并在内存按 baseID 分配（M-1）；
    /// - 快照：跨 await 只持有值类型 ID，不持有 SwiftData 模型（M-3）；
    /// - 孤儿清扫：镜像带标记但 base 在缓存与系统侧都已不存在 → 删除（H-1）。
    /// - Note: 不挂在 EKEventStoreChanged 上，避免与镜像自身写入互相触发。
    @MainActor
    func reconcileAllLunarMirrors() async {
        guard let context = cacheService.context else { return }
        let descriptor = FetchDescriptor<CachedEvent>()
        guard let cached = CacheFetch.optional(descriptor, in: context, operation: "农历镜像批量补窗查询") else {
            return
        }
        // M-3：先收成值类型快照，后续 await 期间不再触碰模型属性
        let snapshots = Self.makeLunarMirrorSnapshots(from: cached)
        let cachedBaseIDs = Set(snapshots.map(\.baseID))

        // M-1：提醒 / 日历窗口各拉取一次；失败则整侧跳过（不能因一次读失败误删镜像）
        var reminderGroups: [String: PrefetchedLunarMirrorGroup] = [:]
        var reminderItems: [String: [String: EKCalendarItem]] = [:]
        var reminderPresence: CompletePresence?
        let remindersAvailable: Bool
        if reminderAuthorizationStatus == .fullAccess {
            if let all = await fetchAllRemindersForMirror() {
                let grouping = Self.groupReminderMirrors(all)
                reminderGroups = grouping.groups
                reminderItems = grouping.items
                // H-1：系统侧存在性取自已拉取的全量列表，不再逐条单点查询
                reminderPresence = CompletePresence(
                    ids: Self.systemBaseIDs(reminders: all),
                    observedAt: Date()
                )
                remindersAvailable = true
            } else {
                AppLogger.sync.error("农历镜像批量补窗：提醒列表读取失败，跳过提醒侧")
                remindersAvailable = false
            }
        } else {
            remindersAvailable = false
        }

        var eventGroups: [String: PrefetchedLunarMirrorGroup] = [:]
        var eventItems: [String: [String: EKCalendarItem]] = [:]
        var eventPresence: CompletePresence?
        let eventsAvailable = authorizationStatus == .fullAccess
        if eventsAvailable {
            // 窗口快照：只用于去重 / 收养，禁止参与删除判定
            let window = Self.mirrorEventWindow(now: Date())
            let windowedEvents = eventStore.events(matching: eventStore.predicateForEvents(
                withStart: window.start,
                end: window.end,
                calendars: nil
            ))
            let grouping = Self.groupEventMirrors(windowedEvents)
            eventGroups = grouping.groups
            eventItems = grouping.items
            // 每日一次全量对账（本函数启动 + 每 24h 调用一次）：删除判定只认完整快照，
            // 窗口外是否存在 base 不能靠窗口数据推断
            let fullEvents = eventStore.events(matching: eventStore.predicateForEvents(
                withStart: .distantPast,
                end: .distantFuture,
                calendars: nil
            ))
            eventPresence = CompletePresence(
                ids: Self.systemBaseIDs(events: fullEvents),
                observedAt: Date()
            )
        }

        // H-1：孤儿清扫（先清后补，避免已删 base 的镜像继续响铃）
        if remindersAvailable || eventsAvailable {
            cleanupOrphanLunarMirrors(
                cachedBaseIDs: cachedBaseIDs,
                reminderGroups: remindersAvailable ? reminderGroups : [:],
                eventGroups: eventsAvailable ? eventGroups : [:],
                reminderItems: remindersAvailable ? reminderItems : [:],
                eventItems: eventsAvailable ? eventItems : [:],
                reminderPresence: reminderPresence,
                eventPresence: eventPresence,
                now: Date()
            )
        }

        // EK 对象不上跨 await 的参数：本轮对象放 MainActor 属性，供 perform 同步取用
        lunarMirrorPrefetchedItems = reminderItems.merging(eventItems) { lhs, _ in lhs }
        defer { lunarMirrorPrefetchedItems.removeAll() }

        for snapshot in snapshots where snapshot.needsReconcile {
            if snapshot.isReminder {
                guard remindersAvailable else { continue }
                await reconcileLunarMirrors(
                    baseID: snapshot.baseID,
                    prefetched: reminderGroups[snapshot.baseID] ?? PrefetchedLunarMirrorGroup()
                )
            } else {
                guard eventsAvailable else { continue }
                await reconcileLunarMirrors(
                    baseID: snapshot.baseID,
                    prefetched: eventGroups[snapshot.baseID] ?? PrefetchedLunarMirrorGroup()
                )
            }
        }
    }

    /// 按复合键删除单条系统侧镜像（提醒 commit / 事件 thisEvent）；单条失败只记日志不中断
    @MainActor
    private func removeMirrorItem(_ item: EKCalendarItem, key: String, context: String) {
        do {
            if let reminder = item as? EKReminder {
                try eventStore.remove(reminder, commit: true)
            } else if let event = item as? EKEvent {
                try eventStore.remove(event, span: .thisEvent)
            }
            AppLogger.sync.debug("\(context, privacy: .public) ok key=\(key, privacy: .public)")
        } catch {
            AppLogger.sync.error("\(context, privacy: .public)失败 key=\(key, privacy: .public): \(String(describing: error))")
        }
    }

    /// H-1：删除孤儿镜像（base 在缓存与系统侧都已不存在）
    /// - 判定：复合键中的 baseID 不在缓存快照，且不在完整系统快照里
    /// - 类型约束：只接受 `CompletePresence?`，窗口快照无法进入删除判定；
    ///   提醒侧全量拉取、事件侧每日一次全量扫描各自构建完整快照
    /// - 防误删：某侧读取失败时 presence 为 nil，`orphanBaseIDs` 返回空集；
    ///   系统侧仍存在一律保留
    /// - 口径：只删未完成的未来镜像，已完成/过期历史保留（与取消农历一致）
    @MainActor
    private func cleanupOrphanLunarMirrors(
        cachedBaseIDs: Set<String>,
        reminderGroups: [String: PrefetchedLunarMirrorGroup],
        eventGroups: [String: PrefetchedLunarMirrorGroup],
        reminderItems: [String: [String: EKCalendarItem]],
        eventItems: [String: [String: EKCalendarItem]],
        reminderPresence: CompletePresence?,
        eventPresence: CompletePresence?,
        now: Date
    ) {
        var orphans: Set<String> = []
        orphans.formUnion(LunarMirrorPolicy.orphanBaseIDs(
            cachedBaseIDs: cachedBaseIDs,
            mirrorBaseIDs: Set(reminderGroups.keys),
            presence: reminderPresence
        ))
        orphans.formUnion(LunarMirrorPolicy.orphanBaseIDs(
            cachedBaseIDs: cachedBaseIDs,
            mirrorBaseIDs: Set(eventGroups.keys),
            presence: eventPresence
        ))
        guard !orphans.isEmpty else { return }

        for baseID in orphans {
            if let group = reminderGroups[baseID] {
                for key in LunarMirrorPolicy.keysToDelete(scope: .orphan, existing: group.existing, now: now) {
                    guard let reminder = reminderItems[baseID]?[key] as? EKReminder else { continue }
                    removeMirrorItem(reminder, key: key, context: "农历孤儿提醒清理")
                }
            }
            if let group = eventGroups[baseID] {
                for key in LunarMirrorPolicy.keysToDelete(scope: .orphan, existing: group.existing, now: now) {
                    guard let event = eventItems[baseID]?[key] as? EKEvent else { continue }
                    removeMirrorItem(event, key: key, context: "农历孤儿事件清理")
                }
            }
        }
    }

    @MainActor
    private func performLunarMirrorReconcile(
        baseID: String,
        prefetched: PrefetchedLunarMirrorGroup?
    ) async {
        guard let base = findCachedEvent(eventID: baseID) else { return }
        let now = Date()

        // 按 base 类型选择镜像来源；批量补窗复用一次拉取的分组，单条触发则现场拉取
        let existing: [ExistingLunarMirror]
        var byID: [String: EKCalendarItem] = [:]

        if let prefetched {
            existing = prefetched.existing
            // EK 对象只在 MainActor 属性里同步取用（跨 await 只传 Sendable 值快照）
            byID = lunarMirrorPrefetchedItems[baseID] ?? [:]
        } else if base.isReminder {
            guard reminderAuthorizationStatus == .fullAccess else { return }
            guard let all = await fetchAllRemindersForMirror() else {
                AppLogger.sync.error("农历镜像对账失败：提醒列表不可用 base=\(baseID)")
                return
            }
            let grouping = Self.groupReminderMirrors(all)
            existing = grouping.groups[baseID]?.existing ?? []
            byID = grouping.items[baseID] ?? [:]
        } else {
            guard authorizationStatus == .fullAccess else { return }
            let window = Self.mirrorEventWindow(now: now)
            let events = eventStore.events(matching: eventStore.predicateForEvents(
                withStart: window.start,
                end: window.end,
                calendars: nil
            ))
            let grouping = Self.groupEventMirrors(events)
            existing = grouping.groups[baseID]?.existing ?? []
            byID = grouping.items[baseID] ?? [:]
        }

        // M3：await 之后重新校验 base 仍存活——「编辑后立刻删除」时不得再写孤儿镜像
        guard let liveBase = findCachedEvent(eventID: baseID) else { return }
        // S5：已创建键登记损坏 ≠ 空列表——本轮不动镜像、不改登记，等数据恢复
        guard !liveBase.mirrorKeysCorrupt else {
            AppLogger.sync.error("农历镜像对账跳过：已创建键登记 JSON 损坏 base=\(baseID, privacy: .public)")
            return
        }

        let plan = LunarMirrorPolicy.reconcile(
            baseID: baseID,
            // 日历事件没有完成推进：起始期已过期时，本体不再覆盖当前期，镜像从当前时刻起铺
            currentDate: liveBase.isReminder
                ? liveBase.startDate
                : Self.eventMirrorCursor(startDate: liveBase.startDate, isAllDay: liveBase.isAllDay, now: now),
            origin: liveBase.originStartDate ?? liveBase.startDate ?? now,
            specState: liveBase.recurrenceSpecState,
            isLunar: liveBase.isLunar,
            validStart: liveBase.validStartDate,
            validEnd: liveBase.validEndDate,
            // 完成历史仅提醒有语义；日历事件不写完成标记
            completedDates: liveBase.isReminder ? liveBase.completedOccurrenceDates : [],
            now: now,
            existing: existing,
            knownKeys: liveBase.mirrorKeys,
            suppressedKeys: liveBase.suppressedMirrorKeys,
            // S5：抑制列表损坏 → 本轮跳过重建，且不回写抑制列表
            suppressedKeysUnavailable: liveBase.suppressedMirrorKeysCorrupt,
            expectedFingerprint: Self.mirrorContentFingerprint(base: liveBase),
            // M2：跳过节假日的任务，休日不铺镜像（与展开同一判定器）
            skipHolidays: liveBase.skipHolidays,
            isRestDay: { HolidaySkipResolver.isRestDay($0, context: self.cacheService.context) }
        )

        for key in plan.deleteOccurrenceIDs {
            guard let item = byID[key] else { continue }
            removeMirrorItem(item, key: key, context: "农历镜像删除")
        }

        for key in plan.updateOccurrenceIDs {
            guard let item = byID[key], let parsed = CachedEvent.parseOccurrenceID(key) else { continue }
            do {
                try updateLunarMirror(base: liveBase, item: item, date: parsed.occurrence)
                AppLogger.sync.debug("农历镜像更新 ok key=\(key, privacy: .public)")
            } catch {
                AppLogger.sync.error("农历镜像更新失败 key=\(key, privacy: .public): \(String(describing: error))")
            }
        }

        for key in plan.completeOccurrenceIDs {
            guard let reminder = byID[key] as? EKReminder, !reminder.isCompleted else { continue }
            reminder.isCompleted = true
            do {
                try eventStore.save(reminder, commit: true)
            } catch {
                AppLogger.sync.error("农历镜像完成标记失败 key=\(key, privacy: .public): \(String(describing: error))")
            }
        }

        var createdKeys: [String] = []
        for date in plan.createDates {
            // M3：创建前再确认 base 仍存活，避免删除路径并发清理后又把镜像写回来
            guard findCachedEvent(eventID: baseID) != nil else { return }
            do {
                if liveBase.isReminder {
                    try createLunarMirror(base: liveBase, date: date)
                } else {
                    try createLunarEventMirror(base: liveBase, date: date)
                }
                createdKeys.append(CachedEvent.makeOccurrenceID(baseID: baseID, occurrence: date))
            } catch {
                AppLogger.sync.error("农历镜像创建失败 base=\(baseID) date=\(date, privacy: .public): \(String(describing: error))")
            }
        }

        // 登记/抑制落库：登记用于下次区分「手删」与「未创建」
        let registryChanged = !plan.knownKeysToAdd.isEmpty
            || !plan.knownKeysToRemove.isEmpty
            || !createdKeys.isEmpty
            || !plan.suppressedKeysToAdd.isEmpty
            || !plan.suppressedKeysToRemove.isEmpty
        if registryChanged {
            var known = liveBase.mirrorKeys
            known.removeAll { plan.knownKeysToRemove.contains($0) }
            known.append(contentsOf: plan.knownKeysToAdd)
            known.append(contentsOf: createdKeys)
            liveBase.mirrorKeys = known

            // S5：抑制列表损坏时不回写，避免把损坏数据覆盖成空列表
            if !liveBase.suppressedMirrorKeysCorrupt {
                var suppressed = liveBase.suppressedMirrorKeys
                suppressed.removeAll { plan.suppressedKeysToRemove.contains($0) }
                suppressed.append(contentsOf: plan.suppressedKeysToAdd)
                liveBase.suppressedMirrorKeys = suppressed
            }

            do {
                try cacheService.context?.save()
            } catch {
                AppLogger.sync.error("农历镜像登记落库失败 base=\(baseID): \(String(describing: error))")
            }
        }
    }

    /// 删除某条 base 的未来未完成镜像（删 base / 取消农历共用）；已完成与过期保留
    /// - Note: 删除判据统一由 LunarMirrorPolicy.keysToDelete(.baseRemoved) 提供，
    ///   提醒与事件只是一次拉取分组，不再各自维护过滤条件
    @MainActor
    func deleteLunarMirrors(baseID: String, isReminder: Bool) async {
        let now = Date()
        let group: PrefetchedLunarMirrorGroup?
        var items: [String: EKCalendarItem] = [:]
        if isReminder {
            guard reminderAuthorizationStatus == .fullAccess else { return }
            guard let all = await fetchAllRemindersForMirror() else { return }
            let grouping = Self.groupReminderMirrors(all)
            group = grouping.groups[baseID]
            items = grouping.items[baseID] ?? [:]
        } else {
            guard authorizationStatus == .fullAccess else { return }
            let window = Self.mirrorEventWindow(now: now)
            let events = eventStore.events(matching: eventStore.predicateForEvents(
                withStart: window.start,
                end: window.end,
                calendars: nil
            ))
            let grouping = Self.groupEventMirrors(events)
            group = grouping.groups[baseID]
            items = grouping.items[baseID] ?? [:]
        }
        guard let group else { return }

        let keys = LunarMirrorPolicy.keysToDelete(scope: .baseRemoved, existing: group.existing, now: now)
        for key in keys {
            guard let item = items[key] else { continue }
            removeMirrorItem(item, key: key, context: "农历镜像删除")
        }
    }

    /// 镜像提醒共用字段配置（创建/更新同形）：标题/到期/闹钟/优先级/notes 标记；日历与保存由调用方决定
    @MainActor
    private func configureReminderMirrorFields(_ reminder: EKReminder, base: CachedEvent, date: Date) {
        reminder.title = base.title
        reminder.dueDateComponents = Self.makeDueComponents(from: date, isAllDay: base.isAllDay)
        reminder.alarms = Self.makeAlarms(
            offsets: base.reminderOffsets.isEmpty ? nil : base.reminderOffsets,
            minutes: nil,
            reminderDueDate: date
        )
        reminder.priority = Self.ekPriority(from: EventPriority(rawValue: base.priority))
        let key = CachedEvent.makeOccurrenceID(baseID: base.eventID, occurrence: date)
        reminder.notes = LunarMirrorPlan.marker(
            occurrenceID: key,
            fingerprint: Self.mirrorContentFingerprint(base: base)
        )
    }

    /// 镜像事件共用字段配置（创建/更新同形）：标题/全天/起止/闹钟/notes 标记；日历选择与保存由调用方决定
    @MainActor
    private func configureEventMirrorFields(_ event: EKEvent, base: CachedEvent, date: Date) {
        event.title = base.title
        event.isAllDay = base.isAllDay
        if base.isAllDay {
            let start = Calendar.current.startOfDay(for: date)
            event.startDate = start
            event.endDate = Calendar.current.date(byAdding: .day, value: 1, to: start)
                ?? start.addingTimeInterval(86400)
        } else {
            event.startDate = date
            event.endDate = date.addingTimeInterval(Self.mirrorDuration(base: base))
        }
        event.alarms = Self.makeAlarms(
            offsets: base.reminderOffsets.isEmpty ? nil : base.reminderOffsets,
            minutes: base.reminderMinutes == 0 ? nil : base.reminderMinutes
        )
        let key = CachedEvent.makeOccurrenceID(baseID: base.eventID, occurrence: date)
        event.notes = LunarMirrorPlan.marker(
            occurrenceID: key,
            fingerprint: Self.mirrorContentFingerprint(base: base)
        )
    }

    /// 新建一条普通、不循环的镜像提醒（系统侧只显示公历）
    @MainActor
    private func createLunarMirror(base: CachedEvent, date: Date) throws {
        let reminder = EKReminder(eventStore: eventStore)
        reminder.calendar = eventStore.defaultCalendarForNewReminders() ?? eventStore.calendars(for: .reminder).first
        guard reminder.calendar != nil else {
            throw EventError.noReminderCalendarAvailable
        }
        configureReminderMirrorFields(reminder, base: base, date: date)
        try eventStore.save(reminder, commit: true)
    }

    /// 新建一条普通、不循环的镜像日历事件（系统侧只显示公历）
    /// - Note: 全天事件沿用现有口径：start=当日 00:00，end=次日 00:00（exclusive），不引入新偏移
    @MainActor
    private func createLunarEventMirror(base: CachedEvent, date: Date) throws {
        let event = EKEvent(eventStore: eventStore)
        guard let calendar = eventStore.calendar(withIdentifier: base.calendarID)
            ?? eventStore.defaultCalendarForNewEvents
            ?? calendars.first else {
            throw EventError.noCalendarAvailable
        }
        event.calendar = calendar
        configureEventMirrorFields(event, base: base, date: date)
        try eventStore.save(event, span: .thisEvent)
    }

    /// 原地更新已存在的镜像内容（期次/键不变），避免「本体改了、系统侧仍是旧值」
    @MainActor
    private func updateLunarMirror(base: CachedEvent, item: EKCalendarItem, date: Date) throws {
        if let reminder = item as? EKReminder {
            configureReminderMirrorFields(reminder, base: base, date: date)
            try eventStore.save(reminder, commit: true)
            return
        }
        guard let event = item as? EKEvent else { return }
        configureEventMirrorFields(event, base: base, date: date)
        // M-2：本体移动日历后镜像同步迁移；目标日历取不到时按创建路径回退默认日历，
        // 保存失败则不落指纹，下次对账重试（不会出现「指纹已改但日历没迁」的假同步）
        if let target = eventStore.calendar(withIdentifier: base.calendarID)
            ?? eventStore.defaultCalendarForNewEvents
            ?? calendars.first,
            event.calendar != target {
            event.calendar = target
        }
        try eventStore.save(event, span: .thisEvent)
    }

    /// 镜像内容指纹：覆盖镜像会写入的全部可见字段。
    /// - Note: 用稳定哈希（非 String.hashValue），保证跨启动比较一致；
    ///         日期/期次本身由复合键承载，不重复纳入。
    static func mirrorContentFingerprint(base: CachedEvent) -> String {
        let offsets = base.reminderOffsets.map(String.init).joined(separator: ",")
        let payload = [
            base.title,
            base.isAllDay ? "1" : "0",
            String(base.priority),
            offsets,
            String(base.reminderMinutes),
            base.isReminder ? "r" : "e",
            base.isReminder ? "" : base.calendarID,
            String(base.isReminder ? 0 : Int(Self.mirrorDuration(base: base)))
        ].joined(separator: "|")
        return LunarMirrorPlan.stableHash(payload)
    }

    /// 日历镜像的检索窗口：一年历史（保留已完成/过期镜像）+ 14 个月未来（12 个月窗口 + 余量）
    private static func mirrorEventWindow(now: Date, calendar: Calendar = .current) -> (start: Date, end: Date) {
        let start = calendar.date(byAdding: .month, value: -12, to: now) ?? now.addingTimeInterval(-365 * 86400)
        let end = calendar.date(byAdding: .month, value: 14, to: now) ?? now.addingTimeInterval(420 * 86400)
        return (start, end)
    }

    /// 日历事件没有完成推进：本体只覆盖起始期；起始期已过期时从当前时刻之后铺设镜像
    private static func eventMirrorCursor(startDate: Date?, isAllDay: Bool, now: Date) -> Date? {
        guard let startDate else { return nil }
        if isAllDay {
            let today = Calendar.current.startOfDay(for: now)
            let startDay = Calendar.current.startOfDay(for: startDate)
            return startDay > today ? startDate : today
        }
        return startDate > now ? startDate : now
    }

    /// 日历镜像时长：沿用本体 start→end，异常/零长回退 1 小时（全天单独处理）
    private static func mirrorDuration(base: CachedEvent) -> TimeInterval {
        guard let start = base.startDate, let end = base.endDate else { return 3600 }
        let duration = end.timeIntervalSince(start)
        return duration > 0 ? duration : 3600
    }

    /// 原始提醒列表（含镜像；区别于对外 `fetchReminders` 的过滤结果）
    private func fetchAllRemindersForMirror() async -> [EKReminder]? {
        let predicate = eventStore.predicateForReminders(in: nil)
        return await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders)
            }
        }
    }

    // MARK: - Sync

    /// 根据 eventID 查找缓存事件（读路径：查不到与查询失败都返回 nil，失败落日志）
    @MainActor
    private func findCachedEvent(eventID: String) -> CachedEvent? {
        guard let context = cacheService.context else { return nil }
        var descriptor = FetchDescriptor<CachedEvent>(predicate: #Predicate { $0.eventID == eventID })
        descriptor.fetchLimit = 1
        return CacheFetch.optional(descriptor, in: context, operation: "缓存事件回查")?.first
    }

    /// 循环规则写路径专用：查询失败抛出，区分「本体不存在」与「查询失败」（审计 M3）
    @MainActor
    private func findCachedEventOrThrow(eventID: String) throws -> CachedEvent? {
        guard let context = cacheService.context else {
            throw RecurrenceUpdateError.cacheContextUnavailable
        }
        var descriptor = FetchDescriptor<CachedEvent>(predicate: #Predicate { $0.eventID == eventID })
        descriptor.fetchLimit = 1
        return try CacheFetch.throwing(descriptor, in: context, operation: "循环规则更新回查").first
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
            recurrenceSpec: cached.recurrenceSpec,
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
    // MARK: - BUG-05 锚点原语（非农历 monthly/yearly）

    /// 按锚点 origin 与序号 index 构造第 N 期（spec 单一真源）：
    /// 月末/闰日缺失日期直接跳过（不再回弹），时分秒保留 origin。
    /// 非 monthly/yearly 或农历返回 nil（走原有取整语义）
    static func anchoredOccurrence(origin: Date, index: Int, recurrenceType: RecurrenceType) -> Date? {
        guard recurrenceType == .monthly || recurrenceType == .yearly,
              let spec = RecurrenceSpec.legacy(from: recurrenceType, anchor: origin, isLunar: false) else {
            return nil
        }
        return spec.occurrence(index: index, origin: origin, isLunar: false)
    }

    /// 反向求相位：date 相对 origin 的期序号（monthly 按月差、yearly 按年差）；
    /// 非锚点适用类型返回 nil。用于完成推进/回退与存量完成历史迁移
    static func anchoredIndex(of date: Date, origin: Date, recurrenceType: RecurrenceType) -> Int? {
        guard recurrenceType == .monthly || recurrenceType == .yearly,
              let spec = RecurrenceSpec.legacy(from: recurrenceType, anchor: origin, isLunar: false) else {
            return nil
        }
        return spec.index(of: date, origin: origin, isLunar: false)
    }

    /// 确定性单步推进到下一个 occurrence（单条化 plan step 3）
    /// 与当前时间无关；月/年按锚定日构造并跳过缺失日期；农历走 chinese Calendar；
    /// 跳过节假日不在此处理——语义 v3 为显示层静默过滤，不改写序列
    static func nextOccurrence(after date: Date, recurrenceType: RecurrenceType, isLunar: Bool, origin: Date? = nil) -> Date? {
        guard let spec = RecurrenceSpec.legacy(
            from: recurrenceType,
            anchor: origin ?? date,
            isLunar: isLunar
        ) else { return nil }
        return spec.next(after: date, origin: origin ?? date, isLunar: isLunar)
    }

    /// nextOccurrence 的逆运算（反向单步，bug: recurring-past-occurrence-invisible）
    /// - Note: 未传 origin 时保持「游标单位回退」旧语义（存量锚点回填按步走链，不重新锚定）
    static func previousOccurrence(before date: Date, recurrenceType: RecurrenceType, isLunar: Bool, origin: Date? = nil) -> Date? {
        guard let origin else {
            let calendar = isLunar ? Calendar(identifier: .chinese) : Calendar.current
            switch recurrenceType {
            case .unlimited, .daily: return calendar.date(byAdding: .day, value: -1, to: date)
            case .weekly: return calendar.date(byAdding: .weekOfYear, value: -1, to: date)
            case .monthly: return calendar.date(byAdding: .month, value: -1, to: date)
            case .yearly: return calendar.date(byAdding: .year, value: -1, to: date)
            case .hourly: return calendar.date(byAdding: .hour, value: -1, to: date)
            case .none, .custom: return nil
            }
        }
        guard let spec = RecurrenceSpec.legacy(from: recurrenceType, anchor: origin, isLunar: isLunar) else { return nil }
        return spec.previous(before: date, origin: origin, isLunar: isLunar)
    }

    /// 展开起点对齐（bug: reminder-starved-by-badge-expansion）：
    /// 直接跳到「≤ windowStart 的最近相位」，调用方从此点开始产出，避免从远古锚点空转
    static func alignedExpansionStart(origin: Date, recurrenceType: RecurrenceType, isLunar: Bool, windowStart: Date) -> Date? {
        guard !isLunar,
              let spec = RecurrenceSpec.legacy(from: recurrenceType, anchor: origin, isLunar: false) else {
            return nil
        }
        return spec.alignedOccurrence(before: windowStart, origin: origin, isLunar: false)
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
    static func advanceRecurrenceDate(_ date: Date, recurrenceType: RecurrenceType, origin: Date? = nil) -> Date {
        guard let spec = RecurrenceSpec.legacy(from: recurrenceType, anchor: origin ?? date, isLunar: false) else {
            return date
        }
        return advanceRecurrenceDate(date, spec: spec, isLunar: false, originOverride: origin)
    }

    /// spec 版推进：按同一真源遵守间隔/多选星期/第 N 个周几/结束条件；结果保证 > Date()
    static func advanceRecurrenceDate(
        _ date: Date,
        spec: RecurrenceSpec,
        isLunar: Bool,
        originOverride: Date? = nil
    ) -> Date {
        let now = Date()
        guard date <= now else { return date }
        let anchor = originOverride ?? date
        var current = date
        // 相位对齐跳到 ≤ now 的最近一期，避免远古锚点逐次空转
        if let aligned = spec.alignedOccurrence(before: now, origin: anchor, isLunar: isLunar), aligned >= date {
            current = aligned
        }
        var iterations = 0
        while current <= now {
            guard let next = spec.next(after: current, origin: anchor, isLunar: isLunar) else {
                // 结束重复已到达：无未来期次，保留原值
                return date
            }
            current = next
            iterations += 1
            if iterations >= 4000 {
                return now
            }
        }
        return current
    }
}
