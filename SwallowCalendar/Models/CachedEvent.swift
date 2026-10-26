//
//  CachedEvent.swift
//  SwallowCalendar
//
//  用于本地缓存系统日历事件，加快应用启动速度
//

import Foundation
import SwiftData
import EventKit
import CryptoKit
import os

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
    
    /// 是否为系统提醒来源（区分系统提醒与系统日历事件）
    var isReminder: Bool = false
    
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
    
    /// 提醒提前分钟数（0=不提醒）；多级模式下恒等于 reminderOffsets 的最大值（硬不变量，G1）
    /// 注意：@Model 宏不保留 didSet（已探针实证），G1 反向重写由 setReminderMinutesRewritingMax 显式承担
    var reminderMinutes: Int = 0

    /// G1 反向重写（原 didSet 联动，因 @Model 宏丢弃 didSet 而显式化）：
    /// 直赋单级 minutes 时把多级 offsets 最高档替换为新值并去重，
    /// 维护硬不变量 reminderMinutes == offsets.max()；直赋点必须调用本方法而非直接赋值
    func setReminderMinutesRewritingMax(_ value: Int) {
        reminderMinutes = value
        guard let json = reminderOffsetsJSON,
              let data = json.data(using: .utf8),
              var offsets = try? JSONDecoder().decode([Int].self, from: data),
              !offsets.isEmpty,
              let oldMax = offsets.max(),
              value != oldMax else { return }
        if let idx = offsets.firstIndex(of: oldMax) {
            offsets[idx] = value
        } else {
            offsets.append(value)
        }
        let normalized = Array(Set(offsets)).sorted()
        if let data = try? JSONEncoder().encode(normalized) {
            reminderOffsetsJSON = String(data: data, encoding: .utf8)
        }
    }

    /// 多级提醒提前分钟数（JSON 持久化，plan 步骤 6；nil = 未设置多级，回退单级）
    var reminderOffsetsJSON: String?
    
    /// 用户选择的事件颜色（十六进制，nil 时使用日历颜色）
    var eventColorHex: String?

    /// 智能跳过节假日：勾选后生效日按节假日休/班标识顺延（plan 步骤①；
    /// 带默认值新增属性走 SwiftData 轻量迁移，存量行自动补 false）
    var skipHolidays: Bool = false

    /// 任务有效期区间（spec/task-validity-period AC-1~AC-6；带默认值走 SwiftData 轻量迁移）
    /// 落库时已归一化：start=当天 00:00:00 / end=当天 23:59:59；nil = 该端不限制
    var validStartDate: Date?
    var validEndDate: Date?

    /// 循环任务完成历史（JSON 持久化，单条化 plan step 1；nil = 无完成历史）
    var completedOccurrenceDatesJSON: String?

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

    /// 多级提醒提前分钟数组（计算属性，真源为 reminderOffsetsJSON 镜像 EventKit 多 alarm）
    /// 读取：解码 JSON，未设置/坏数据/空数组回退 [reminderMinutes]（单级语义）
    /// 写入：去重升序编码 JSON，并维护硬不变量 reminderMinutes == max
    var reminderOffsets: [Int] {
        get {
            guard let json = reminderOffsetsJSON,
                  let data = json.data(using: .utf8),
                  let offsets = try? JSONDecoder().decode([Int].self, from: data),
                  !offsets.isEmpty else {
                return [reminderMinutes]
            }
            return offsets
        }
        set {
            let normalized = Array(Set(newValue)).sorted()
            guard !normalized.isEmpty else {
                // 空数组：清空多级，回退单级语义（reminderMinutes 保持当前值）
                reminderOffsetsJSON = nil
                return
            }
            if let data = try? JSONEncoder().encode(normalized) {
                reminderOffsetsJSON = String(data: data, encoding: .utf8)
            }
            // 硬不变量：reminderMinutes == offsets.max()
            reminderMinutes = normalized.max() ?? 0
        }
    }
    
    /// 编码多级偏移数组为持久化 JSON（nil/空 → nil，未设置多级语义）
    /// 供同步/中转模型比较与落库使用；提取端已去重升序，此处原样编码
    static func encodeOffsetsJSON(_ offsets: [Int]?) -> String? {
        guard let offsets, !offsets.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(offsets) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 循环任务完成历史（计算属性，真源为 completedOccurrenceDatesJSON，单条化 plan step 1）
    /// 读取：解码 JSON，未设置/坏数据回退空数组；写入：去重升序编码，空数组清除 JSON
    var completedOccurrenceDates: [Date] {
        get {
            guard let json = completedOccurrenceDatesJSON,
                  let data = json.data(using: .utf8),
                  let dates = try? JSONDecoder().decode([Date].self, from: data) else {
                return []
            }
            return dates
        }
        set {
            let normalized = Array(Set(newValue)).sorted()
            guard !normalized.isEmpty else {
                completedOccurrenceDatesJSON = nil
                return
            }
            if let data = try? JSONEncoder().encode(normalized) {
                completedOccurrenceDatesJSON = String(data: data, encoding: .utf8)
            }
        }
    }

    // MARK: - 有效期判定（spec/task-validity-period AC-1；plan step 3）

    /// occurrence 是否落在有效期区间内（闭区间；双端 nil = 不限制）
    /// 前置约定：validStartDate/validEndDate 落库时已归一化（00:00:00 / 23:59:59）
    func isWithinValidity(_ occurrence: Date) -> Bool {
        if let validStart = validStartDate, occurrence < validStart { return false }
        if let validEnd = validEndDate, occurrence > validEnd { return false }
        return true
    }

    // MARK: - 复合 occurrence ID（单条化 plan step 2）

    /// 复合 occurrence eventID 格式前缀（`|` 分隔符安全：UUID 恒不含 `|`）
    private static let occurrenceMarker = "|occ:"

    /// 构造复合 occurrence eventID："<baseID>|occ:<epoch>"
    /// 全项目复合 ID 构造唯一入口，禁止调用方手写拼接
    static func makeOccurrenceID(baseID: String, occurrence: Date) -> String {
        baseID + occurrenceMarker + String(Int(occurrence.timeIntervalSince1970))
    }

    /// 解析复合 occurrence eventID；普通 eventID（不含标记）返回 nil
    /// 全项目复合 ID 解析唯一入口
    static func parseOccurrenceID(_ eventID: String) -> (baseID: String, occurrence: Date)? {
        guard let markerRange = eventID.range(of: occurrenceMarker) else { return nil }
        let baseID = String(eventID[..<markerRange.lowerBound])
        let epochString = String(eventID[markerRange.upperBound...])
        guard !baseID.isEmpty, let epoch = TimeInterval(epochString) else { return nil }
        return (baseID, Date(timeIntervalSince1970: epoch))
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
        isReminder: Bool = false,
        isCompleted: Bool = false,
        priority: Int = 0,
        groupId: String? = nil,
        groupIndex: Int = -1,
        recurrenceType: RecurrenceType = .none,
        isLunar: Bool = false,
        reminderMinutes: Int = 0,
        reminderOffsetsJSON: String? = nil,
        eventColorHex: String? = nil,
        skipHolidays: Bool = false,
        validStartDate: Date? = nil,
        validEndDate: Date? = nil
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
        self.isReminder = isReminder
        self.isCompleted = isCompleted
        self.priority = priority
        self.groupId = groupId
        self.groupIndex = groupIndex
        self.recurrenceTypeRaw = recurrenceType.rawValue
        self.isLunar = isLunar
        self.reminderMinutes = reminderMinutes
        self.reminderOffsetsJSON = reminderOffsetsJSON
        self.eventColorHex = eventColorHex
        self.skipHolidays = skipHolidays
        self.validStartDate = validStartDate
        self.validEndDate = validEndDate
        self.lastUpdated = Date()
    }
}

// MARK: - 缓存变更通知

/// D2/G7v2：缓存事件变更通知（字符串名风格，同项目既有通知）。
/// 发送点为结构性位置：syncEvents/syncReminders 保存成功、编辑保存、完成/取消完成路径；
/// 消费方（状态栏徽标）收到后即时刷新，30s 定时器仅作兜底
extension Notification.Name {
    static let cachedEventsChanged = Notification.Name("CachedEventsChanged")
}

// MARK: - 缓存服务

@MainActor
@Observable
final class EventCacheService {
    static let shared = EventCacheService()

    private var modelContainer: ModelContainer?
    /// 主上下文：由 ContentView 注入环境 ModelContext，确保与 @Query 使用同一上下文
    private var mainContext: ModelContext?

    // B-13：events 与 reminders 拆分为独立同步标志——共用一个标志时，
    // 手动与后台并发同步不同数据源会导致后到者被静默跳过
    var isSyncingEvents = false

    var isSyncingReminders = false

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
        
        // B-24：时间窗口过滤下沉到 SwiftData 谓词，避免全表加载后内存过滤。
        // 左边界放宽 1 秒以兼容零长事件（start==end==窗口起点需纳入，见 filterEvents B-1 注释）：
        // 非零长事件 s < e 时 (s >= wStart || e > wStart) ⟺ e > wStart，故统一用 e > wStart 表达
        let widenedStart = startDate.addingTimeInterval(-1)
        // 哨兵日期用局部常量捕获：#Predicate 宏展开后 Date.distantPast 是静态成员
        // keypath（Value<Date.Type>），不符合 StandardPredicateExpression；
        // 局部常量被捕获后转为 Value 表达式即合法
        let distantPast = Date.distantPast
        let distantFuture = Date.distantFuture
        // 循环任务单条化：本体行 startDate 只代表「下一次 occurrence」，
        // 窗口内 occurrence 序列可能超出本体行自身时间范围，粗筛放宽为
        // 「recurrenceType != none 且 startDate < 窗口右界」即命中（展开后再精确过滤）
        let noneRaw = RecurrenceType.none.rawValue
        let predicate = #Predicate<CachedEvent> { event in
            ((event.startDate ?? distantPast) < endDate
                && (event.endDate ?? distantFuture) > widenedStart)
                || (event.recurrenceTypeRaw != nil
                    && event.recurrenceTypeRaw != noneRaw
                    && (event.startDate ?? distantPast) < endDate)
        }

        let descriptor = FetchDescriptor<CachedEvent>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.startDate)]
        )

        do {
            let events = try context.fetch(descriptor)
            // 循环任务行分离展开为 occurrence 实例（未落库），其余走原有精确过滤
            let recurring = events.filter { $0.recurrenceType != .none }
            let normal = events.filter { $0.recurrenceType == .none }
            let expanded = recurring.flatMap {
                expandOccurrences(of: $0, windowStart: startDate, windowEnd: endDate, context: context)
            }
            // 展开实例与普通行共用同一精确过滤（零长/重叠边界 + 日历过滤），并按开始时间归位排序
            return (filterEvents(normal, from: startDate, to: endDate, calendars: calendars, includeNoDateReminders: includeNoDateReminders)
                + filterEvents(expanded, from: startDate, to: endDate, calendars: calendars, includeNoDateReminders: false))
                .sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
        } catch {
            return []
        }
    }

    /// 循环任务单条展开为窗口内 occurrence 实例（未落库，单条化 plan step 6）：
    /// ① 完成历史窗口内日期 → isCompleted=true 历史行（历史事实不过 skipHolidays）；
    /// ② 从 startDate 链式 nextOccurrence 推进（与完成推进链共用，保持自洽），
    ///    未完成 occurrence 落休日按 v3 语义静默跳过；迭代上限 4000 防失控。
    /// 有效期过滤（spec/task-validity-period AC-2 AC-3，plan step 4）：①② 均只产出
    /// 有效期内的 occurrence；② 对已完成 occurrence 不再追加（历史行由 ① 独家产出，
    /// 避免冻结场景 startDate 停在已完成 X 时产出重复行），并按结束端越界早退
    /// - Parameter includeHolidaySkipped: true 时休日实例仍产出（月历语义：无顺延，
    ///   原休日格显示并保留「已智能跳过」标识）；列表路径默认 false 静默跳过不变
    func expandOccurrences(of base: CachedEvent, windowStart: Date, windowEnd: Date, context: ModelContext, includeHolidaySkipped: Bool = false) -> [CachedEvent] {
        guard let baseStart = base.startDate else { return [base] }
        let duration = (base.endDate ?? baseStart).timeIntervalSince(baseStart)
        let completedSet = Set(base.completedOccurrenceDates.map { $0.timeIntervalSince1970 })
        var result: [CachedEvent] = []
        // ① 完成历史行（有效期外不产出）
        for occ in base.completedOccurrenceDates where occ >= windowStart && occ < windowEnd && base.isWithinValidity(occ) {
            result.append(makeOccurrenceInstance(of: base, occurrence: occ, duration: duration, isCompleted: true))
        }
        // ② 未完成序列展开
        var occ = baseStart
        var iterations = 0
        while occ < windowEnd {
            // 有效期结束端之外（闭区间端点之后）全部越界，提前退出
            if let validEnd = base.validEndDate, occ > validEnd { break }
            let done = completedSet.contains(occ.timeIntervalSince1970)
            // 已完成 occurrence 的展示行由 ① 独家产出，② 不追加，避免冻结场景重复行
            if !done, base.isWithinValidity(occ) {
                let instanceEnd = occ.addingTimeInterval(duration)
                // 与窗口重叠才产出（零长按 B-1 覆盖开始日语义）
                if occ >= windowStart || instanceEnd > windowStart {
                    // 休日处理（仅未完成 occurrence；序列本身不改写）：
                    // 默认静默跳过（列表语义）；月历传 includeHolidaySkipped=true 保留休日实例
                    if base.skipHolidays, !includeHolidaySkipped, HolidaySkipResolver.isRestDay(occ, context: context) {
                        // 静默跳过：不产出
                    } else {
                        result.append(makeOccurrenceInstance(of: base, occurrence: occ, duration: duration, isCompleted: false))
                    }
                }
            }
            guard let next = CalendarService.nextOccurrence(after: occ, recurrenceType: base.recurrenceType, isLunar: base.isLunar) else { break }
            occ = next
            iterations += 1
            if iterations >= 4000 {
                AppLogger.cache.error("循环任务展开达迭代上限，中止展开：\(base.eventID, privacy: .public)")
                break
            }
        }
        return result
    }

    /// 月历视图合并入口（bug: calendar-grid-recurring-invisible）：
    /// @Query 直查主表只能看到循环任务 base 行（过去首实例），看不到未落库的未来
    /// occurrence——本方法把传入行拆为普通行 + 循环展开实例（休日实例保留供标识），
    /// 本体行被替换，语义与 getEvents 一致；调用方负责按月窗口传入 @Query 结果
    func mergedDisplayEvents(from rows: [CachedEvent], windowStart: Date, windowEnd: Date, context: ModelContext) -> [CachedEvent] {
        let recurring = rows.filter { $0.recurrenceType != .none }
        let normal = rows.filter { $0.recurrenceType == .none }
        let expanded = recurring.flatMap {
            expandOccurrences(of: $0, windowStart: windowStart, windowEnd: windowEnd, context: context, includeHolidaySkipped: true)
        }
        return (normal + expanded).sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
    }

    /// 构造 occurrence 实例（未落库）：拷贝展示相关字段，eventID 用复合格式，
    /// groupId/groupIndex 置空（单条化后停用）
    private func makeOccurrenceInstance(of base: CachedEvent, occurrence: Date, duration: TimeInterval, isCompleted: Bool) -> CachedEvent {
        CachedEvent(
            eventID: CachedEvent.makeOccurrenceID(baseID: base.eventID, occurrence: occurrence),
            title: base.title,
            startDate: occurrence,
            endDate: occurrence.addingTimeInterval(duration),
            isAllDay: base.isAllDay,
            calendarID: base.calendarID,
            calendarTitle: base.calendarTitle,
            calendarColorHex: base.calendarColorHex,
            category: base.category,
            isReminder: base.isReminder,
            isCompleted: isCompleted,
            priority: base.priority,
            recurrenceType: base.recurrenceType,
            isLunar: base.isLunar,
            reminderMinutes: base.reminderMinutes,
            reminderOffsetsJSON: base.reminderOffsetsJSON,
            eventColorHex: base.eventColorHex,
            skipHolidays: base.skipHolidays,
            validStartDate: base.validStartDate,
            validEndDate: base.validEndDate
        )
    }
    
    private func filterEvents(_ events: [CachedEvent], from startDate: Date, to endDate: Date, calendars: [EKCalendar]?, includeNoDateReminders: Bool) -> [CachedEvent] {
        var filtered = events.filter { event in
            guard let start = event.startDate, let end = event.endDate else {
                return includeNoDateReminders
            }
            // B-1：零长事件（start==end，如仅日期提醒映射产物 start==end==当日00:00）
            // 视为覆盖开始当天——原判定 end > startDate 恒为 false，导致到期当天不可见。
            // 采用审计备选方案"零长事件特殊处理"，避免单日查询右边界+1 天把次日
            // 00:00 开始的事件误纳入当天
            if start == end {
                return start >= startDate && start < endDate
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
    /// B-28：返回同步是否成功（保存失败/guard 提前退出均返回 false），
    /// manualSync 依赖此结果回传 UI；@discardableResult 保持旧调用方兼容
    @MainActor
    @discardableResult
    func syncEvents(from calendarService: CalendarService, calendars: [EKCalendar]) async -> Bool {
        guard let context = self.context else { return false }
        guard !isSyncingEvents else { return false }
        
        isSyncingEvents = true
        defer {
            isSyncingEvents = false
        }

        // 单条化 plan step 9：存量循环任务组一次性迁移（幂等，UserDefaults 门控保护，
        // 全表扫描覆盖 EKEvent/EKReminder 两类旧组）
        migrateRecurringGroups(context: context, calendarService: calendarService)

        // 同步过去1年和未来2年的事件
        let now = Date()
        let startDate = Calendar.current.date(byAdding: .year, value: -1, to: now)!
        let endDate = Calendar.current.date(byAdding: .year, value: 2, to:now)!
        
        // 从系统日历获取事件
        let systemEvents = calendarService.fetchEvents(from: startDate, to: endDate, calendars: calendars)
        // 获取现有的缓存事件，构建 eventID → 行 全表映射
        // B-10：不做窗口过滤——事件移出同步窗口后旧行不进索引，else 分支会插入
        // 同 eventID 新行触发 @Attribute(.unique) 冲突导致整次保存失败；
        // 全表构建让更新路径能命中窗口外旧行
        var existingByID: [String: CachedEvent] = [:]
        let descriptor = FetchDescriptor<CachedEvent>()
        if let existing = try? context.fetch(descriptor) {
            for event in existing {
                existingByID[event.eventID] = event
            }
        }
        
        let newIDs = Set(systemEvents.map { $0.id })

        // 删除已不存在的系统事件（缓存中存在但系统中已不存在）
        // B-10：仅同步窗口内的行参与删除判定，窗口外旧行不在本次同步范围
        //（由 cleanupOldEvents 按保留期限清理）
        let deletedIDs = Set(existingByID.keys).subtracting(newIDs)
        for eventID in deletedIDs {
            if let event = existingByID[eventID] {
                if let start = event.startDate, let end = event.endDate,
                   !(start < endDate && end > startDate) {
                    continue
                }
                // 跳过提醒事件（由 syncReminders 管理）
                guard !event.isReminder else { continue }
                // 跳过用户分类事件（由用户操作管理，不在系统同步中删除）
                // E-10：user 事件为缓存+EK 双写，走到此处说明 EK 侧已无此事件
                //（可能被用户在系统日历 App 直接删除），缓存条目将永久残留，
                // 记日志暴露问题以便排查
                guard event.category != .user else {
                    AppLogger.cache.warning("syncEvents 跳过删除 user 事件（EK 侧可能已删除）id=\(eventID)")
                    continue
                }
                // 跳过订阅分类事件（由 syncSubscriptionEvents 管理）
                guard event.category != .subscription else { continue }
                // 删除系统中已不存在的事件
                context.delete(event)
            }
        }
        
        // 更新或插入事件
        for event in systemEvents {
            if let existing = existingByID[event.id] {
                // 仅当事项内容、时间、完成情况有变化时才更新，否则跳过
                let newTitle = event.title
                let newStart = event.startDate ?? now
                let newEnd = event.endDate ?? now
                // 从 EKEvent 的 notes 中读取完成状态
                // 注意：notes 无 [SC_COMPLETED] 标记时保留缓存状态，不强制刷回 false。
                // 原因：历史已办事项在 [SC_COMPLETED] 机制引入（2026-05）之前标记完成，
                // 其 EKEvent notes 中并无标记，若强制刷回会导致已办在重启后重新变回过期待办弹窗。
                var newIsCompleted = existing.isCompleted
                // B-8：与插入路径对称——notes 含来源标记时恢复 user 分类，
                // 避免 EK 侧分类信息变化后缓存残留旧分类
                var newCategory = event.category
                // B-25：notes 随 fetchEvents 一并带出，不再逐条 getEvent 跨进程查询；
                // notes 为空串等价于原 EKEvent.notes 为 nil（无任何标记）
                let notes = event.notes ?? ""
                if notes.contains("[SC_COMPLETED]") {
                    newIsCompleted = true
                } else if newIsCompleted {
                    // 缓存已完成但 EK 无标记（历史已办）：补写标记到系统日历，
                    // 让系统日历成为完成状态真源，清缓存/换设备重新同步也能恢复完成状态
                    CalendarService.shared.ensureCompletedMarker(for: event.id)
                }
                if notes.contains("此事项来自SwallowCalendar应用") {
                    newCategory = .user
                }
                // 有变更才更新，避免不必要的写入
                let newReminderMinutes = event.reminderMinutes
                // 步骤7：多级偏移随 EK alarm 数组带出，编码后与缓存比较——变更检测
                // 必须同时比较 reminderMinutes 与 offsets（Architect steelman 采纳项）
                let newOffsetsJSON = CachedEvent.encodeOffsetsJSON(event.reminderOffsets)
                let offsetsChanged = existing.reminderOffsetsJSON != newOffsetsJSON
                // B-8：变更检测与赋值补齐 isAllDay/calendarTitle/calendarColorHex/category，
                // 避免 EK 侧修改后缓存残留旧值
                if existing.title != newTitle || existing.startDate != newStart || existing.endDate != newEnd || existing.isCompleted != newIsCompleted || existing.reminderMinutes != newReminderMinutes || offsetsChanged || existing.isAllDay != event.isAllDay || existing.calendarTitle != event.calendarTitle || existing.calendarColorHex != event.calendarColorHex || existing.category != newCategory {
                    if existing.isCompleted != newIsCompleted {
                        AppLogger.cache.warning("syncEvents isCompleted \(existing.isCompleted ? "true" : "false")→\(newIsCompleted ? "true" : "false") id=\(existing.eventID)")
                    }
                    existing.title = newTitle
                    existing.startDate = newStart
                    existing.endDate = newEnd
                    existing.isCompleted = newIsCompleted
                    // 双写同源一致值（JSON 与 minutes 均来自 EK，本就满足 max 不变量）
                    existing.reminderOffsetsJSON = newOffsetsJSON
                    existing.reminderMinutes = newReminderMinutes
                    existing.isAllDay = event.isAllDay
                    existing.calendarTitle = event.calendarTitle
                    existing.calendarColorHex = event.calendarColorHex
                    existing.category = newCategory
                    existing.lastUpdated = Date()
                }
            } else {
                // B-9：优先按 calendar identifier 匹配日历（title 同名/本地化差异
                // 会取错日历导致 calendarID 记录为空串后被过滤消失），
                // identifier 匹配失败时回退 title 匹配
                let targetCalendar = calendars.first { $0.calendarIdentifier == event.calendarID }
                    ?? calendars.first { $0.title == event.calendarTitle }
                let calendarID = targetCalendar?.calendarIdentifier ?? ""
                
                // 检查EKEvent的备注，判断是否是SwallowCalendar事项
                var category = event.category
                // 从 EKEvent 的 notes 中恢复完成状态（跨设备/清缓存后重新同步时
                // 已完成事项仍能以已完成状态插入缓存，不丢失完成状态）
                var isCompletedFromNotes = false
                // B-25：notes 随 fetchEvents 一并带出，不再逐条 getEvent 跨进程查询
                let notes = event.notes ?? ""
                if notes.contains("此事项来自SwallowCalendar应用") {
                    category = .user
                }
                if notes.contains("[SC_COMPLETED]") {
                    isCompletedFromNotes = true
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
                    category: category,
                    isCompleted: isCompletedFromNotes,
                    reminderMinutes: event.reminderMinutes,
                    reminderOffsetsJSON: CachedEvent.encodeOffsetsJSON(event.reminderOffsets)
                )
                context.insert(cached)
            }
        }
        
        do {
            try context.save()
            lastSyncTime = Date()
            // 清理超过保留期限的旧事件
            cleanupOldEvents(context: context, before: startDate)
            // D2/G7v2：系统日历回流完成，广播缓存变更（徽标即时刷新）
            NotificationCenter.default.post(name: .cachedEventsChanged, object: nil)
            return true
        } catch {
            AppLogger.cache.error("同步保存失败: \(String(describing: error))")
            return false
        }
    }

    /// 一次性迁移：将旧版本中通过 calendarTitle == "提醒" 标识的记录补设 isReminder 标记
    /// 迁移完成后通过 UserDefaults 标记，后续不再执行
    @MainActor
    private func migrateReminderFlag(context: ModelContext) {
        let migrationKey = "EventCacheService.isReminderMigrationDone"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }

        let descriptor = FetchDescriptor<CachedEvent>()
        guard let existing = try? context.fetch(descriptor) else { return }

        var migratedCount = 0
        for event in existing where !event.isReminder && event.calendarTitle == "提醒" {
            event.isReminder = true
            migratedCount += 1
        }

        if migratedCount > 0 {
            do {
                try context.save()
                AppLogger.cache.info("迁移了 \(migratedCount) 条提醒记录的 isReminder 标记")
                UserDefaults.standard.set(true, forKey: migrationKey)
            } catch {
                // 保存失败，不标记迁移完成，下次重试
                AppLogger.cache.error("迁移保存失败: \(String(describing: error))")
            }
        } else {
            // 无数据需要迁移，直接标记完成
            UserDefaults.standard.set(true, forKey: migrationKey)
        }
    }

    /// 一次性迁移：旧版多实例循环任务组（groupId != nil）合并为单条推进式记录（单条化 plan step 9）
    /// - 每组保留「最早未完成实例」行作单条（全完成组保留最晚一条已完成实例），
    ///   已完成实例日期升序并入完成历史，groupId/groupIndex 置空（幂等标记，重查自然 no-op）
    /// - 先删其余行的 EK 记录（任一失败该组整体放弃，缓存不动下次重试），后改缓存并统一 save
    /// - 全部组成功后才写 UserDefaults 门控；无组数据直接标记，避免每次启动全表扫描
    @MainActor
    func migrateRecurringGroups(context: ModelContext, calendarService: CalendarService) {
        let migrationKey = "EventCacheService.recurringGroupsMigrationDone"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }

        let descriptor = FetchDescriptor<CachedEvent>()
        guard let all = try? context.fetch(descriptor) else { return }
        let groupRows = all.filter { $0.groupId != nil }
        guard !groupRows.isEmpty else {
            // 无组数据（新库/已迁移库）：直接标记完成
            UserDefaults.standard.set(true, forKey: migrationKey)
            return
        }

        let groups = Dictionary(grouping: groupRows, by: { $0.groupId! })
        var failedGroups = 0
        for (groupID, rows) in groups {
            // 开始时间升序：有未完成实例取最早一条，全完成组取最晚一条
            let sorted = rows.sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
            guard let keeper = sorted.first(where: { !$0.isCompleted }) ?? sorted.last else { continue }
            let others = rows.filter { $0 !== keeper }

            // 先删 EK 侧其余记录：任一失败该组整体放弃（缓存不动，下次启动重试）
            var ekAllRemoved = true
            for row in others {
                if !calendarService.deleteEKRecordIfExists(eventID: row.eventID, isReminder: row.isReminder) {
                    ekAllRemoved = false
                    break
                }
            }
            guard ekAllRemoved else {
                failedGroups += 1
                AppLogger.cache.error("循环任务组迁移 EK 删除失败，整组保留待重试 groupId=\(groupID, privacy: .public)")
                continue
            }

            // 已完成实例日期升序并入完成历史（含 keeper 自身已完成场景）；
            // keeper 的 isCompleted/recurrenceType/startDate 自带旧值即为单条语义，无需改写
            keeper.completedOccurrenceDates = sorted.filter { $0.isCompleted }.compactMap { $0.startDate }
            keeper.groupId = nil
            keeper.groupIndex = -1
            keeper.lastUpdated = Date()
            for row in others {
                context.delete(row)
            }
        }

        do {
            try context.save()
            if failedGroups == 0 {
                UserDefaults.standard.set(true, forKey: migrationKey)
                AppLogger.cache.info("循环任务组迁移完成，共 \(groups.count) 组")
            } else {
                AppLogger.cache.warning("循环任务组迁移部分失败（\(failedGroups)/\(groups.count) 组），门控未写下次重试")
            }
        } catch {
            // 保存失败：门控不写，已改组下次按 groupId 缺失幂等收敛
            AppLogger.cache.error("循环任务组迁移保存失败: \(String(describing: error))")
        }
    }

    /// 同步系统提醒到本地缓存
    /// - Note: 无到期时间的提醒也会同步，但不受日期范围限制
    /// - Returns: 同步是否成功（guard 提前退出/保存失败返回 false），供手动同步错误反馈
    @MainActor
    @discardableResult
    func syncReminders(from calendarService: CalendarService) async -> Bool {
        guard let context = self.context else { return false }
        guard !isSyncingReminders else { return false }
        guard AppSettings.shared.syncSystemReminders else { return false }

        isSyncingReminders = true
        defer { isSyncingReminders = false }

        // 一次性迁移：将旧版本中通过 calendarTitle == "提醒" 标识的记录补设 isReminder 标记
        migrateReminderFlag(context: context)

        // 从系统提醒获取（获取所有提醒，包括已完成的，以正确同步外部状态变化）
        let reminders = await calendarService.fetchReminders(includeCompleted: true)

        // 获取现有的提醒，构建字典以优化查询
        var existingByID: [String: CachedEvent] = [:]
        let descriptor = FetchDescriptor<CachedEvent>()
        if let existing = try? context.fetch(descriptor) {
            for event in existing where event.isReminder {
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

        // 更新或插入提醒
        for reminder in reminders {
            if let existing = existingByID[reminder.id] {
                // 仅当事项内容、时间、完成情况或提醒时间有变化时才更新，否则跳过
                let newTitle = reminder.title
                let newStart = reminder.startDate
                let newEnd = reminder.endDate
                let newIsCompleted = reminder.isCompleted
                let newReminderMinutes = reminder.reminderMinutes
                // 步骤7：变更检测同时比较 offsets（多级偏移随 EK alarm 数组带出）
                let newOffsetsJSON = CachedEvent.encodeOffsetsJSON(reminder.reminderOffsets)
                let offsetsChanged = existing.reminderOffsetsJSON != newOffsetsJSON
                // 有变更才更新，避免不必要的写入
                if existing.title != newTitle || existing.startDate != newStart || existing.endDate != newEnd || existing.isCompleted != newIsCompleted || existing.reminderMinutes != newReminderMinutes || offsetsChanged {
                    if existing.isCompleted != newIsCompleted {
                        AppLogger.cache.warning("syncReminders isCompleted \(existing.isCompleted ? "true" : "false")→\(newIsCompleted ? "true" : "false") id=\(existing.eventID)")
                    }
                    existing.title = newTitle
                    existing.startDate = newStart
                    existing.endDate = newEnd
                    existing.isCompleted = newIsCompleted
                    // 双写同源一致值（JSON 与 minutes 均来自 EK，本就满足 max 不变量）
                    existing.reminderOffsetsJSON = newOffsetsJSON
                    existing.reminderMinutes = newReminderMinutes
                    existing.lastUpdated = Date()
                }
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
                    isReminder: true,
                    isCompleted: reminder.isCompleted,
                    priority: 0,
                    reminderMinutes: reminder.reminderMinutes,
                    reminderOffsetsJSON: CachedEvent.encodeOffsetsJSON(reminder.reminderOffsets)
                )
                context.insert(cached)
            }
        }

        do {
            try context.save()
            lastSyncTime = Date()
            // D2/G7v2：系统提醒回流完成，广播缓存变更（徽标即时刷新）
            NotificationCenter.default.post(name: .cachedEventsChanged, object: nil)
        } catch {
            AppLogger.cache.error("提醒保存失败: \(String(describing: error))")
            return false
        }
        return true
    }

    /// 清除所有提醒缓存（isReminder 为 true 的记录）
    @MainActor
    func clearRemindersCache() {
        guard let context = self.context else { return }
        
        let descriptor = FetchDescriptor<CachedEvent>(
            predicate: #Predicate<CachedEvent> { event in
                event.isReminder == true
            }
        )
        
        if let events = try? context.fetch(descriptor) {
            for event in events {
                context.delete(event)
            }
            try? context.save()
        }
    }

    /// V-38：即时删除指定订阅源的全部缓存事件（源被禁用时调用），
    /// 原实现依赖下一次后台同步兜底，禁用后事件残留一个同步周期
    @MainActor
    func deleteSubscriptionEvents(sourceURL: String) {
        guard let context else { return }
        let subscriptionCategory = EventCategory.subscription.rawValue
        let descriptor = FetchDescriptor<CachedEvent>(
            predicate: #Predicate<CachedEvent> { event in
                event.calendarID == sourceURL && event.categoryRaw == subscriptionCategory
            }
        )
        // fetch 失败与空结果分开处理：fetch 异常需暴露（与落库失败同口径），空结果属正常
        guard let events = try? context.fetch(descriptor) else {
            AppLogger.cache.warning("查询禁用订阅源缓存事件失败，残留事件待下次同步清理: \(sourceURL)")
            return
        }
        guard !events.isEmpty else { return }
        for event in events {
            context.delete(event)
        }
        do {
            try context.save()
            AppLogger.cache.info("已清除被禁用订阅源的缓存事件 count=\(events.count)")
        } catch {
            // 删除落库失败时禁用源的事件会残留（V-38 症状），必须暴露而非静默吞掉
            AppLogger.cache.error("清除禁用订阅源缓存事件保存失败: \(error.localizedDescription)")
        }
    }

    /// 同步 ICS 订阅日历事件到本地缓存
    /// - Parameter sources: 启用的 ICS 订阅源列表
    /// - Note: 采用增删改模式：已存在的更新、源中不存在的删除、应用中没有的新增
    ///         获取失败的源保留旧数据不删除
    /// - Returns: 同步是否成功（guard 提前退出/启用源全部获取失败/保存失败返回 false），
    ///            供手动同步错误反馈；获取失败保留旧数据属容错设计，但需向 UI 暴露
    @MainActor
    @discardableResult
    func syncSubscriptionEvents(sources: [CustomCalendarSource]) async -> Bool {
        guard let context = self.context else { return false }
        guard !isSubscriptionSyncing else { return false }
        isSubscriptionSyncing = true
        defer { isSubscriptionSyncing = false }

        let enabledSources = sources.filter { $0.isEnabled }

        // 1. 获取所有启用源的事件数据，记录成功获取的源 URL
        let icsService = ICSService.shared
        var fetchedEventsBySource: [(source: CustomCalendarSource, events: [ICSEvent])] = []
        var fetchedSourceURLs = Set<String>()

        for source in enabledSources {
            let events: [ICSEvent]
            if let cached = icsService.loadCached(url: source.icsURL) {
                events = cached
            } else {
                do {
                    events = try await icsService.fetchAndParse(url: source.icsURL)
                } catch {
                    // 获取失败，跳过该源（保留其旧数据不被删除）
                    continue
                }
            }
            fetchedEventsBySource.append((source: source, events: events))
            fetchedSourceURLs.insert(source.icsURL)
        }

        // 2. 如果有启用的源但全部获取失败，保留旧数据不删除
        if !enabledSources.isEmpty && fetchedEventsBySource.isEmpty {
            return false
        }

        // 3. 构建新数据的 eventID → 数据 映射
        // B-12：eventID 加源 URL 前缀，避免跨源 uid 冲突时 last-write-wins 覆盖；
        // 无 uid 时用 summary+dtstart 的 SHA256 稳定哈希替代 "\(summary)_\(timestamp)"
        //（String.hashValue 每次启动随机种子，不可用作持久化标识）
        var newEventsByID: [String: (source: CustomCalendarSource, icsEvent: ICSEvent)] = [:]
        for (source, events) in fetchedEventsBySource {
            // 对同源事件按 uid 去重：相同 uid 只保留一条
            var eventsByUID: [String: ICSEvent] = [:]
            for icsEvent in events {
                let uid = icsEvent.uid.isEmpty
                    ? Self.stableHash("\(icsEvent.summary)_\(icsEvent.startDate?.timeIntervalSince1970 ?? 0)")
                    : icsEvent.uid
                if eventsByUID[uid] == nil {
                    eventsByUID[uid] = icsEvent
                }
            }

            for (_, icsEvent) in eventsByUID {
                guard let startDate = icsEvent.startDate else { continue }
                let stableUID = icsEvent.uid.isEmpty
                    ? Self.stableHash("\(icsEvent.summary)_\(startDate.timeIntervalSince1970)")
                    : icsEvent.uid
                let eventID = "ics-\(source.icsURL)-\(stableUID)"
                newEventsByID[eventID] = (source: source, icsEvent: icsEvent)
            }
        }

        let newIDs = Set(newEventsByID.keys)

        // 4. 获取现有缓存中的所有订阅事件，构建 eventID → CachedEvent 映射
        var existingByID: [String: CachedEvent] = [:]
        let subscriptionCategory = EventCategory.subscription.rawValue
        let descriptor = FetchDescriptor<CachedEvent>(
            predicate: #Predicate<CachedEvent> { event in
                event.categoryRaw == subscriptionCategory
            }
        )
        if let existing = try? context.fetch(descriptor) {
            for event in existing {
                existingByID[event.eventID] = event
            }
        }

        // 启用源的 URL 集合（用于判断缓存事件的来源是否仍启用）
        let enabledSourceURLs = Set(enabledSources.map { $0.icsURL })

        // 5. 删除：缓存中存在但新数据中不存在的订阅事件
        //    对于获取失败的源（源启用但未在 fetchedSourceURLs 中），保留其旧数据
        let deletedIDs = Set(existingByID.keys).subtracting(newIDs)
        for eventID in deletedIDs {
            if let event = existingByID[eventID] {
                // 如果事件来源是启用的源且该源获取成功 → 删除（源中已无此事件）
                // 如果事件来源不是任何启用的源 → 删除（源已被禁用）
                // 如果事件来源是启用的源但获取失败 → 保留（网络问题，不丢失数据）
                if fetchedSourceURLs.contains(event.calendarID) {
                    context.delete(event)
                } else if !enabledSourceURLs.contains(event.calendarID) {
                    context.delete(event)
                }
                // else: 源启用但获取失败，保留旧数据
            }
        }

        // 6. 更新或插入
        for (eventID, newData) in newEventsByID {
            let icsEvent = newData.icsEvent
            let source = newData.source
            guard let startDate = icsEvent.startDate else { continue }
            let endDate = icsEvent.endDate ?? startDate

            if let existing = existingByID[eventID] {
                // 仅当事项内容、时间有变化时才更新，否则跳过
                let newTitle = icsEvent.summary
                // 有变更才更新，避免不必要的写入
                if existing.title != newTitle || existing.startDate != startDate || existing.endDate != endDate {
                    existing.title = newTitle
                    existing.startDate = startDate
                    existing.endDate = endDate
                    existing.lastUpdated = Date()
                }
            } else {
                // 插入新事件
                let cached = CachedEvent(
                    eventID: eventID,
                    title: icsEvent.summary,
                    startDate: startDate,
                    endDate: endDate,
                    // B-11：按 ICS DTSTART 是否含时间判定，不再硬编码全天
                    isAllDay: icsEvent.isAllDay,
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
            // B-30：保存失败必须记录日志，静默吞掉会丢数据且无法排查
            AppLogger.cache.error("订阅同步保存失败: \(String(describing: error))")
            return false
        }
        return true
    }

    /// B-12：跨启动稳定的内容哈希（String.hashValue 每次启动随机种子，不可用作持久化标识）
    private static func stableHash(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
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

    /// 清除缓存（分类保护：仅清系统/订阅缓存）
    /// - Note: 用户自建事项与提醒缓存不清除——非"缓存-EK 双写"场景下
    ///         （如关闭了"同步到系统日历"），清缓存会导致用户数据永久丢失
    func clearCache() {
        guard let context = self.context else { return }

        let descriptor = FetchDescriptor<CachedEvent>()
        if let events = try? context.fetch(descriptor) {
            var deletedCount = 0
            for event in events {
                // E-1 分类过滤：跳过用户事项与提醒（与 cleanupOldEvents 保护逻辑同源），
                // 系统/订阅缓存正常清除，重新同步即可恢复
                if event.category == .user || event.isReminder {
                    continue
                }
                context.delete(event)
                deletedCount += 1
            }
            if deletedCount > 0 {
                try? context.save()
            }
            AppLogger.cache.info("清除缓存：删除 \(deletedCount) 条系统/订阅缓存，用户事项与提醒已保留")
        }
    }
    
    /// E-9：已完成用户事项/提醒的保留窗口（天），超过后从本地缓存清理
    private static let userEventRetentionDays = 365

    /// 清理超过保留期限的旧事件（保留 startDate 之前的事件）
    /// E-9：已完成的用户事项/提醒超过保留窗口后清理；未完成的永不清理
    private func cleanupOldEvents(context: ModelContext, before cutoffDate: Date) {
        let descriptor = FetchDescriptor<CachedEvent>()
        guard let events = try? context.fetch(descriptor) else { return }

        var deletedCount = 0
        var userDeletedCount = 0
        // E-9：用户数据清理基准为"365 天前"，与系统缓存用的 cutoffDate（同步窗口起点）分开计算
        let userRetentionCutoff = Calendar.current.date(byAdding: .day, value: -Self.userEventRetentionDays, to: Date())!

        for event in events {
            // E-9：用户事项与提醒改为有条件清理——已完成且 endDate 早于保留窗口才删除，
            // 未完成的永不清理，避免用户数据意外丢失
            if event.category == .user || event.isReminder {
                if event.isCompleted, let endDate = event.endDate, endDate < userRetentionCutoff {
                    context.delete(event)
                    userDeletedCount += 1
                }
                continue
            }
            // 订阅分类不清理（由订阅同步自行管理）
            if event.category == .subscription {
                continue
            }
            // B-19：未来窗口外（endDate 超出同步窗口上界 2 年）的系统事件为残留行
            //（如外部编辑推远后恰逢同步失败），仅靠过去侧清理无法回收
            let futureWindowLimit = Calendar.current.date(byAdding: .year, value: 2, to: Date())!
            if let endDate = event.endDate, endDate > futureWindowLimit {
                context.delete(event)
                deletedCount += 1
                continue
            }
            // 删除早于保留期限且已过期的事件
            if let endDate = event.endDate, endDate < cutoffDate {
                context.delete(event)
                deletedCount += 1
            }
        }

        if deletedCount > 0 || userDeletedCount > 0 {
            try? context.save()
            AppLogger.cache.info("清理过期缓存：系统事件 \(deletedCount) 条，已完成用户事项/提醒 \(userDeletedCount) 条（保留 \(Self.userEventRetentionDays) 天）")
        }
    }
}
