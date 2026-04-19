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
    
    /// 开始时间
    var startDate: Date
    
    /// 结束时间
    var endDate: Date
    
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
    
    /// 缓存更新时间
    var lastUpdated: Date
    
    var category: EventCategory {
        get { EventCategory(rawValue: categoryRaw) ?? .system }
        set { categoryRaw = newValue.rawValue }
    }
    
    /// 是否为订阅日历
    var isSubscription: Bool {
        category == .subscription
    }
    
    init(
        eventID: String,
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        calendarID: String,
        calendarTitle: String,
        calendarColorHex: String,
        category: EventCategory = .system,
        isCompleted: Bool = false,
        priority: Int = 0
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
    func getEvents(for date: Date, calendars: [EKCalendar]? = nil) -> [CachedEvent] {
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
                event.startDate < endOfDay && event.endDate >= startOfDay
            }
            
            // 如果指定了日历且非空，进一步过滤
            if let calendars = calendars, !calendars.isEmpty {
                let calendarIDs = Set(calendars.map { $0.calendarIdentifier })
                events = events.filter { calendarIDs.contains($0.calendarID) }
            }
            
            return events
        } catch {
            print("[EventCache] 获取事件失败: \(error)")
            return []
        }
    }
    
    /// 获取日期范围内的事件
    func getEvents(from startDate: Date, to endDate: Date, calendars: [EKCalendar]? = nil) -> [CachedEvent] {
        guard let context = modelContext else { return [] }
        
        // 获取所有事件后手动过滤
        let descriptor = FetchDescriptor<CachedEvent>(
            sortBy: [SortDescriptor(\.startDate)]
        )
        
        do {
            var events = try context.fetch(descriptor)
            
            // 过滤日期范围
            events = events.filter { event in
                event.startDate < endDate && event.endDate >= startDate
            }
            
            if let calendars = calendars, !calendars.isEmpty {
                let calendarIDs = Set(calendars.map { $0.calendarIdentifier })
                events = events.filter { calendarIDs.contains($0.calendarID) }
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
        guard !isSyncing else {
            print("[EventCache] 正在同步中，跳过")
            return
        }
        
        isSyncing = true
        defer { isSyncing = false }
        
        print("[EventCache] 开始同步 \(calendars.count) 个日历的事件")
        
        // 同步过去1年和未来2年的事件
        let now = Date()
        let startDate = Calendar.current.date(byAdding: .year, value: -1, to: now)!
        let endDate = Calendar.current.date(byAdding: .year, value: 2, to:now)!
        
        // 从系统日历获取事件
        let systemEvents = calendarService.fetchEvents(from: startDate, to: endDate, calendars: calendars)
        print("[EventCache] 从系统获取到 \(systemEvents.count) 个事件")
        
        // 获取现有的缓存事件ID
        var existingIDs = Set<String>()
        let descriptor = FetchDescriptor<CachedEvent>()
        if let existing = try? context.fetch(descriptor) {
            existingIDs = Set(existing.map { $0.eventID })
        }
        
        let newIDs = Set(systemEvents.map { $0.id })
        
        // 删除已不存在的系统事件
        let deletedIDs = existingIDs.subtracting(newIDs)
        if !deletedIDs.isEmpty {
            let deleteDescriptor = FetchDescriptor<CachedEvent>()
            if let allEvents = try? context.fetch(deleteDescriptor) {
                let toDelete = allEvents.filter { deletedIDs.contains($0.eventID) }
                for event in toDelete {
                    context.delete(event)
                }
                print("[EventCache] 删除 \(toDelete.count) 个过期事件")
            }
        }
        
        // 更新或插入事件
        for event in systemEvents {
            let eventDescriptor = FetchDescriptor<CachedEvent>()
            if let existing = try? context.fetch(eventDescriptor).first(where: { $0.eventID == event.id }) {
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
            print("[EventCache] 同步完成，缓存事件数: \(systemEvents.count)")
        } catch {
            print("[EventCache] 保存失败: \(error)")
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
            print("[EventCache] 缓存已清除")
        }
    }
}
