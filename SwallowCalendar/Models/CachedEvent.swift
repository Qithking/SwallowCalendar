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

@Observable
final class EventCacheService {
    static let shared = EventCacheService()
    
    private var modelContainer: ModelContainer?
    private var modelContext: ModelContext?
    
    /// 是否正在同步
    var isSyncing = false
    
    /// 最后同步时间
    var lastSyncTime: Date?
    
    private init() {}
    
    /// 设置 ModelContainer
    func configure(with container: ModelContainer) {
        self.modelContainer = container
        self.modelContext = ModelContext(container)
    }
    
    /// 获取 ModelContext
    var context: ModelContext? {
        return modelContext
    }
    
    // MARK: - 查询（从缓存）
    
    /// 获取某天的事件
    /// - Parameter includeNoDateReminders: 是否包含无到期时间的系统提醒，默认 false（日历视图不需要）
    func getEvents(for date: Date, calendars: [EKCalendar]? = nil, includeNoDateReminders: Bool = false) -> [CachedEvent] {
        guard let context = modelContext else { return [] }
        
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        
        // 获取所有事件后手动过滤
        let descriptor = FetchDescriptor<CachedEvent>(
            sortBy: [SortDescriptor(\.startDate)]
        )
        
        do {
            var events = try context.fetch(descriptor)
            
            // 过滤日期范围
            events = events.filter { event in
                // 无日期的提醒（没有到期时间的系统提醒）
                guard let start = event.startDate, let end = event.endDate else {
                    // 根据参数决定是否包含无日期的提醒
                    return includeNoDateReminders
                }
                return start < endOfDay && end >= startOfDay
            }
            
            // 如果指定了日历且非空，进一步过滤（但保留用户分类的事件，包括系统提醒）
            if let calendars = calendars, !calendars.isEmpty {
                let calendarIDs = Set(calendars.map { $0.calendarIdentifier })
                events = events.filter { event in
                    // 用户分类的事件（包括系统提醒）始终保留
                    if event.category == .user { return true }
                    // 其他事件按日历ID过滤
                    return calendarIDs.contains(event.calendarID)
                }
            }
            
            return events
        } catch {
            print("[EventCache] 获取事件失败: \(error)")
            return []
        }
    }
    
    /// 获取日期范围内的事件
    /// - Parameters:
    ///   - includeNoDateReminders: 是否包含无到期时间的系统提醒，默认 false（日历视图不需要）
    func getEvents(from startDate: Date, to endDate: Date, calendars: [EKCalendar]? = nil, includeNoDateReminders: Bool = false) -> [CachedEvent] {
        guard let context = modelContext else { return [] }
        
        // 获取所有事件后手动过滤
        let descriptor = FetchDescriptor<CachedEvent>(
            sortBy: [SortDescriptor(\.startDate)]
        )
        
        do {
            var events = try context.fetch(descriptor)
            
            // 过滤日期范围
            events = events.filter { event in
                // 无日期的提醒（没有到期时间的系统提醒）
                guard let start = event.startDate, let end = event.endDate else {
                    // 根据参数决定是否包含无日期的提醒
                    return includeNoDateReminders
                }
                return start < endDate && end >= startDate
            }
            
            // 如果指定了日历且非空，进一步过滤（但保留用户分类的事件，包括系统提醒）
            if let calendars = calendars, !calendars.isEmpty {
                let calendarIDs = Set(calendars.map { $0.calendarIdentifier })
                events = events.filter { event in
                    // 用户分类的事件（包括系统提醒）始终保留
                    if event.category == .user { return true }
                    // 其他事件按日历ID过滤
                    return calendarIDs.contains(event.calendarID)
                }
            }
            
            return events
        } catch {
            print("[EventCache] 获取事件失败: \(error)")
            return []
        }
    }
    
    // MARK: - 同步
    
    /// 同步日历事件到本地缓存
    @MainActor
    func syncEvents(from calendarService: CalendarService, calendars: [EKCalendar]) async {
        guard let context = modelContext else { return }
        guard !isSyncing else { return }
        
        isSyncing = true
        defer { isSyncing = false }
        
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
                existingByID[event.eventID] = event
            }
        }
        
        let newIDs = Set(systemEvents.map { $0.id })
        
        // 获取当前启用的日历ID集合
        let enabledCalendarIDs = Set(calendars.map { $0.calendarIdentifier })
        
        // 删除已不存在的系统事件（但保留被禁用日历的事件和提醒）
        let deletedIDs = Set(existingByID.keys).subtracting(newIDs)
        for eventID in deletedIDs {
            if let event = existingByID[eventID] {
                // 跳过提醒事件（由 syncReminders 管理）
                guard event.calendarTitle != "提醒" else { continue }
                
                // 只删除启用日历中的事件，保留被禁用日历的缓存
                if enabledCalendarIDs.contains(event.calendarID) {
                    context.delete(event)
                }
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
                existing.lastUpdated = Date()
            } else {
                // 查找对应的EKCalendar获取ID
                let targetCalendar = calendars.first { $0.title == event.calendarTitle }
                let calendarID = targetCalendar?.calendarIdentifier ?? ""
                
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
                    category: event.category
                )
                context.insert(cached)
            }
        }
        
        do {
            try context.save()
            lastSyncTime = Date()
        } catch {
            print("[EventCache] 保存失败: \(error)")
        }
    }

    /// 同步系统提醒到本地缓存
    /// - Note: 无到期时间的提醒也会同步，但不受日期范围限制
    @MainActor
    func syncReminders(from calendarService: CalendarService) async {
        guard let context = modelContext else { return }

        // 从系统提醒获取（不过滤日期，获取所有未完成提醒）
        let reminders = await calendarService.fetchReminders(includeCompleted: false)

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
        } catch {
            print("[EventCache] 提醒保存失败: \(error)")
        }
    }

    /// 清除所有提醒缓存（category为user且calendarTitle为"提醒"的）
    func clearRemindersCache() {
        guard let context = modelContext else { return }

        let descriptor = FetchDescriptor<CachedEvent>()
        if let events = try? context.fetch(descriptor) {
            let remindersToDelete = events.filter { $0.category == .user && $0.calendarTitle == "提醒" }
            for event in remindersToDelete {
                context.delete(event)
            }
            try? context.save()
        }
    }

    /// 清除所有缓存
    func clearCache() {
        guard let context = modelContext else { return }
        
        let descriptor = FetchDescriptor<CachedEvent>()
        if let events = try? context.fetch(descriptor) {
            for event in events {
                context.delete(event)
            }
            try? context.save()
        }
    }
}
