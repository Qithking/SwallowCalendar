//
//  CachedEvent.swift
//  SwallowCalendar
//
//  用于本地缓存系统日历事件，加快应用启动速度
//

import Foundation
import SwiftData
import EventKit

@Model
final class CachedEvent {
    /// 事件ID（来自 EKEvent）
    @Attribute(.unique) var eventID: String
    
    /// 事件标题
    var title: String
    
    /// 开始时间（可选，无到期时间的提醒可能为 nil）
    var startDate: Date?
    
    /// 结束时间（可选，无到期时间的提醒可能为 nil）
    var endDate: Date?
    
    /// 是否全天事件
    var isAllDay: Bool
    
    /// 所属日历ID
    var calendarID: String
    
    /// 所属日历名称
    var calendarTitle: String
    
    /// 日历颜色（十六进制）
    var calendarColorHex: String
    
    /// 事件分类
    var categoryRaw: String = EventCategory.system.rawValue
    
    /// 是否已完成（仅对用户事件有效）
    var isCompleted: Bool = false
    
    /// 优先级 (0=无, 1-9, 9最高)
    var priority: Int = 0
    
    /// 周期任务组ID（同一周期任务的所有实例共享）
    var groupId: String?
    
    /// 周期任务组内序号（0-4，标记在5个中的位置）
    var groupIndex: Int = -1
    
    /// 周期类型
    var recurrenceTypeRaw: String? = RecurrenceType.none.rawValue
    
    /// 是否农历
    var isLunar: Bool = false
    
    /// 缓存更新时间
    var lastUpdated: Date
    
    var category: EventCategory {
        get { EventCategory(rawValue: categoryRaw) ?? .system }
        set { categoryRaw = newValue.rawValue }
    }
    
    var recurrenceType: RecurrenceType {
        get { RecurrenceType(rawValue: recurrenceTypeRaw ?? RecurrenceType.none.rawValue) ?? .none }
        set { recurrenceTypeRaw = newValue.rawValue }
    }
    
    /// 是否为订阅日历
    var isSubscription: Bool {
        category == .subscription
    }
    
    /// 是否有具体的日期时间
    var hasDate: Bool {
        startDate != nil
    }
    
    init(
        eventID: String,
        title: String,
        startDate: Date?,
        endDate: Date?,
        isAllDay: Bool,
        calendarID: String,
        calendarTitle: String,
        calendarColorHex: String,
        category: EventCategory = .system,
        isCompleted: Bool = false,
        priority: Int = 0,
        groupId: String? = nil,
        groupIndex: Int = -1,
        recurrenceType: RecurrenceType = .none,
        isLunar: Bool = false
    ) {
        self.eventID = eventID
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.calendarID = calendarID
        self.calendarTitle = calendarTitle
        self.calendarColorHex = calendarColorHex
        self.categoryRaw = category.rawValue
        self.isCompleted = isCompleted
        self.priority = priority
        self.groupId = groupId
        self.groupIndex = groupIndex
        self.recurrenceTypeRaw = recurrenceType.rawValue
        self.isLunar = isLunar
        self.lastUpdated = Date()
    }
}

// MARK: - 缓存服务

@MainActor
@Observable
final class EventCacheService {
    static let shared = EventCacheService()

    private var modelContainer: ModelContainer?
    /// 主上下文：由 ContentView 注入环境 ModelContext，确保与 @Query 使用同一上下文
    private var mainContext: ModelContext?

    var isSyncing = false

    var isSubscriptionSyncing = false

    var lastSyncTime: Date? {
        didSet {
            UserDefaults.standard.set(lastSyncTime, forKey: "EventCacheService.lastSyncTime")
        }
    }

    private init() {
        self.lastSyncTime = UserDefaults.standard.object(forKey: "EventCacheService.lastSyncTime") as? Date
    }
    
    func configure(with container: ModelContainer) {
        self.modelContainer = container
    }
    
    /// 设置主上下文（由 ContentView 注入环境 ModelContext，确保 @Query 能响应变更）
    func setMainContext(_ context: ModelContext) {
        self.mainContext = context
    }
    
    /// 统一获取上下文：优先使用 mainContext（与 @Query 共享），否则使用容器的 mainContext
    var context: ModelContext? {
        return mainContext ?? modelContainer?.mainContext
    }
    
    // MARK: - 查询（从 SwiftData）
    
    func getEvents(for date: Date, calendars: [EKCalendar]? = nil, includeNoDateReminders: Bool = false) -> [CachedEvent] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        
        return getEvents(from: startOfDay, to: endOfDay, calendars: calendars, includeNoDateReminders: includeNoDateReminders)
    }
    
    func getEvents(from startDate: Date, to endDate: Date, calendars: [EKCalendar]? = nil, includeNoDateReminders: Bool = false) -> [CachedEvent] {
        guard let context = self.context else { return [] }
        
        let descriptor = FetchDescriptor<CachedEvent>(
            sortBy: [SortDescriptor(\.startDate)]
        )
        
        do {
            let events = try context.fetch(descriptor)
            return filterEvents(events, from: startDate, to: endDate, calendars: calendars, includeNoDateReminders: includeNoDateReminders)
        } catch {
            return []
        }
    }
    
    private func filterEvents(_ events: [CachedEvent], from startDate: Date, to endDate: Date, calendars: [EKCalendar]?, includeNoDateReminders: Bool) -> [CachedEvent] {
        var filtered = events.filter { event in
            guard let start = event.startDate, let end = event.endDate else {
                return includeNoDateReminders
            }
            return start < endDate && end > startDate
        }
        
        if let calendars = calendars, !calendars.isEmpty {
            let calendarIDs = Set(calendars.map { $0.calendarIdentifier })
            filtered = filtered.filter { event in
                if event.category == .user || event.category == .subscription { return true }
                return calendarIDs.contains(event.calendarID)
            }
        }
        
        return filtered
    }
    
    // MARK: - 同步
    
    /// 同步日历事件到本地缓存
    @MainActor
    func syncEvents(from calendarService: CalendarService, calendars: [EKCalendar]) async {
        guard let context = self.context else { return }
        guard !isSyncing else { return }
        
        isSyncing = true
        defer {
            isSyncing = false
        }
        
        // 同步过去1年和未来2年的事件
        let now = Date()
        let startDate = Calendar.current.date(byAdding: .year, value: -1, to: now)!
        let endDate = Calendar.current.date(byAdding: .year, value: 2, to:now)!
        
        // 从系统日历获取事件
        let systemEvents = calendarService.fetchEvents(from: startDate, to: endDate, calendars: calendars)
        
        // 获取现有的缓存事件，构建字典以优化查询
        var existingByID: [String: CachedEvent] = [:]
        let descriptor = FetchDescriptor<CachedEvent>()
        if let existing = try? context.fetch(descriptor) {
            for event in existing {
                // 过滤出在同步时间范围内的事件，减少内存占用
                if let start = event.startDate, let end = event.endDate, start >= startDate && end <= endDate {
                    existingByID[event.eventID] = event
                }
            }
        }
        
        let newIDs = Set(systemEvents.map { $0.id })
        
        // 获取当前启用的日历ID集合
        let enabledCalendarIDs = Set(calendars.map { $0.calendarIdentifier })
        
        // 删除已不存在的系统事件（缓存中存在但系统中已不存在）
        let deletedIDs = Set(existingByID.keys).subtracting(newIDs)
        for eventID in deletedIDs {
            if let event = existingByID[eventID] {
                // 跳过提醒事件（由 syncReminders 管理）
                guard event.calendarTitle != "提醒" else { continue }
                // 跳过用户分类事件（由用户操作管理，不在系统同步中删除）
                guard event.category != .user else { continue }
                // 删除系统中已不存在的事件
                context.delete(event)
            }
        }
        
        // 更新或插入事件
        for event in systemEvents {
            if let existing = existingByID[event.id] {
                // 更新现有事件
                existing.title = event.title
                existing.startDate = event.startDate ?? now
                existing.endDate = event.endDate ?? now
                existing.isAllDay = event.isAllDay
                existing.calendarColorHex = event.calendarColorHex
                existing.calendarTitle = event.calendarTitle
                // 同步日历ID（系统日历可能被重新配置）
                if let targetCal = calendars.first(where: { $0.title == event.calendarTitle }) {
                    existing.calendarID = targetCal.calendarIdentifier
                }
                // 保留原有的分类（如果是SwallowCalendar事项，保持为用户分类）
                existing.lastUpdated = Date()
                
                // 从 EKEvent 的 notes 中恢复完成状态
                if let ekEvent = CalendarService.shared.getEvent(withIdentifier: event.id) {
                    if let notes = ekEvent.notes, notes.contains("[SC_COMPLETED]") {
                        existing.isCompleted = true
                    }
                }
            } else {
                // 查找对应的EKCalendar获取ID
                let targetCalendar = calendars.first { $0.title == event.calendarTitle }
                let calendarID = targetCalendar?.calendarIdentifier ?? ""
                
                // 检查EKEvent的备注，判断是否是SwallowCalendar事项
                var category = event.category
                if let ekEvent = CalendarService.shared.getEvent(withIdentifier: event.id) {
                    if let notes = ekEvent.notes, notes.contains("此事项来自SwallowCalendar应用") {
                        category = .user
                    }
                }
                
                // 插入新事件
                let cached = CachedEvent(
                    eventID: event.id,
                    title: event.title,
                    startDate: event.startDate ?? now,
                    endDate: event.endDate ?? now,
                    isAllDay: event.isAllDay,
                    calendarID: calendarID,
                    calendarTitle: event.calendarTitle,
                    calendarColorHex: event.calendarColorHex,
                    category: category
                )
                context.insert(cached)
            }
        }
        
        do {
            try context.save()
            lastSyncTime = Date()
            // 清理超过保留期限的旧事件
            cleanupOldEvents(context: context, before: startDate)
        } catch {
            // 保存失败，记录到日志系统（待实现）
        }
    }

    /// 同步系统提醒到本地缓存
    /// - Note: 无到期时间的提醒也会同步，但不受日期范围限制
    @MainActor
    func syncReminders(from calendarService: CalendarService) async {
        guard let context = self.context else { return }
        guard !isSyncing else { return }
        guard AppSettings.shared.syncSystemReminders else { return }

        // 从系统提醒获取（获取所有提醒，包括已完成的，以正确同步外部状态变化）
        let reminders = await calendarService.fetchReminders(includeCompleted: true)

        // 获取现有的提醒，构建字典以优化查询
        var existingByID: [String: CachedEvent] = [:]
        let descriptor = FetchDescriptor<CachedEvent>()
        if let existing = try? context.fetch(descriptor) {
            for event in existing where event.category == .user && event.calendarTitle == "提醒" {
                existingByID[event.eventID] = event
            }
        }

        let newIDs = Set(reminders.map { $0.id })

        // 删除已不存在的提醒
        let deletedIDs = Set(existingByID.keys).subtracting(newIDs)
        for eventID in deletedIDs {
            if let event = existingByID[eventID] {
                context.delete(event)
            }
        }
        if !deletedIDs.isEmpty {
            try? context.save()
        }

        // 更新或插入提醒
        for reminder in reminders {
            if let existing = existingByID[reminder.id] {
                // 更新现有提醒
                existing.title = reminder.title
                existing.startDate = reminder.startDate
                existing.endDate = reminder.endDate
                existing.isAllDay = reminder.isAllDay
                existing.isCompleted = reminder.isCompleted
                existing.lastUpdated = Date()
            } else {
                // 插入新提醒（支持无到期时间的提醒）
                let cached = CachedEvent(
                    eventID: reminder.id,
                    title: reminder.title,
                    startDate: reminder.startDate,
                    endDate: reminder.endDate,
                    isAllDay: reminder.isAllDay,
                    calendarID: "reminder",
                    calendarTitle: "提醒",
                    calendarColorHex: reminder.calendarColorHex,
                    category: .user,
                    isCompleted: reminder.isCompleted,
                    priority: 0
                )
                context.insert(cached)
            }
        }

        do {
            try context.save()
            lastSyncTime = Date()
        } catch {
            // 提醒保存失败，记录到日志系统（待实现）
        }
    }

    /// 清除所有提醒缓存（category为user且calendarTitle为"提醒"的）
    @MainActor
    func clearRemindersCache() {
        guard let context = self.context else { return }
        
        let userCategory = EventCategory.user.rawValue
        let descriptor = FetchDescriptor<CachedEvent>(
            predicate: #Predicate<CachedEvent> { event in
                event.categoryRaw == userCategory
            }
        )
        
        if let events = try? context.fetch(descriptor) {
            let remindersToDelete = events.filter { $0.calendarTitle == "提醒" }
            for event in remindersToDelete {
                context.delete(event)
            }
            try? context.save()
        }
    }

    /// 同步 ICS 订阅日历事件到本地缓存
    /// - Parameter sources: 启用的 ICS 订阅源列表
    @MainActor
    func syncSubscriptionEvents(sources: [CustomCalendarSource]) async {
        guard let context = self.context else { return }
        guard !isSubscriptionSyncing else { return }
        isSubscriptionSyncing = true
        defer { isSubscriptionSyncing = false }

        // 删除所有现有的订阅分类缓存
        let subscriptionCategory = EventCategory.subscription.rawValue
        let descriptor = FetchDescriptor<CachedEvent>(
            predicate: #Predicate<CachedEvent> { event in
                event.categoryRaw == subscriptionCategory
            }
        )
        if let existing = try? context.fetch(descriptor) {
            for event in existing {
                context.delete(event)
            }
        }

        // 从每个启用的 ICS 源获取事件并写入缓存
        let icsService = ICSService.shared
        for source in sources where source.isEnabled {
            let events: [ICSEvent]
            if let cached = icsService.loadCached(url: source.icsURL) {
                events = cached
            } else {
                do {
                    events = try await icsService.fetchAndParse(url: source.icsURL)
                } catch {
                    continue
                }
            }

            // 对同源事件按 uid 去重：相同 uid 只保留一条
            var eventsByUID: [String: ICSEvent] = [:]
            for icsEvent in events {
                let uid = icsEvent.uid.isEmpty
                    ? "\(icsEvent.summary)_\(icsEvent.startDate?.timeIntervalSince1970 ?? 0)"
                    : icsEvent.uid
                if eventsByUID[uid] == nil {
                    eventsByUID[uid] = icsEvent
                }
            }

            for (uid, icsEvent) in eventsByUID {
                guard let startDate = icsEvent.startDate else { continue }
                let endDate = icsEvent.endDate ?? startDate

                // uid 为空时用 "summary_startTimestamp" 生成稳定 eventID
                let stableUID = icsEvent.uid.isEmpty
                    ? "\(icsEvent.summary)_\(startDate.timeIntervalSince1970)"
                    : icsEvent.uid
                let eventID = "ics-\(stableUID)"

                // exists-before-insert 保护：并发 sync 时，检查该 eventID 是否已存在于数据库（删除已在上面完成，此处兜底）
                let existingDescriptor = FetchDescriptor<CachedEvent>(
                    predicate: #Predicate { $0.eventID == eventID }
                )
                if let existing = try? context.fetch(existingDescriptor), !existing.isEmpty {
                    continue
                }

                let cached = CachedEvent(
                    eventID: eventID,
                    title: icsEvent.summary,
                    startDate: startDate,
                    endDate: endDate,
                    isAllDay: true,
                    calendarID: source.icsURL,
                    calendarTitle: source.name,
                    calendarColorHex: "#FF9500",
                    category: .subscription
                )
                context.insert(cached)
            }
        }

        do {
            try context.save()
            lastSyncTime = Date()
        } catch {
            // 保存失败
        }
    }

    /// 清除所有系统日历的缓存（不含订阅日历事件、用户事件和提醒）
    /// 用于所有系统日历都关闭时，清除对应的缓存数据
    @MainActor
    func clearSystemCalendarCache() {
        guard let context = self.context else { return }

        let descriptor = FetchDescriptor<CachedEvent>()
        if let events = try? context.fetch(descriptor) {
            // 只删除系统日历的缓存，保留订阅日历事件、用户事件和提醒
            let eventsToDelete = events.filter { $0.category == .system }
            for event in eventsToDelete {
                context.delete(event)
            }
            try? context.save()
        }
    }

    /// 清除所有缓存
    func clearCache() {
        guard let context = self.context else { return }
        
        let descriptor = FetchDescriptor<CachedEvent>()
        if let events = try? context.fetch(descriptor) {
            for event in events {
                context.delete(event)
            }
            try? context.save()
        }
    }
    
    /// 清理超过保留期限的旧事件（保留 startDate 之前的事件）
    private func cleanupOldEvents(context: ModelContext, before cutoffDate: Date) {
        let descriptor = FetchDescriptor<CachedEvent>()
        guard let events = try? context.fetch(descriptor) else { return }
        
        var deletedCount = 0
        for event in events {
            // 跳过用户分类、订阅分类和提醒事件
            if event.category == .user || event.category == .subscription || event.calendarTitle == "提醒" {
                continue
            }
            // 删除早于保留期限且已过期的事件
            if let endDate = event.endDate, endDate < cutoffDate {
                context.delete(event)
                deletedCount += 1
            }
        }
        
        if deletedCount > 0 {
            try? context.save()
            print("[EventCacheService] 清理了 \(deletedCount) 个过期系统日历事件")
        }
    }
}
