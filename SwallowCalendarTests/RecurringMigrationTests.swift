//
//  RecurringMigrationTests.swift
//  SwallowCalendarTests
//
//  循环任务单条化 Behavior 7：存量循环任务组一次性迁移（plan step 9）
//  - 分组查 groupId≠nil：每组保留「最早未完成实例」行作单条（全完成组保留最晚一条已完成实例）
//  - 已完成实例日期升序并入完成历史；groupId/groupIndex 置空（幂等标记，重查自然 no-op）
//  - 删其余缓存行 + 对应 EK 记录；全部组成功后才写 UserDefaults 门控
//
//  测试环境 EventKit 无授权 → EK 查询返回 nil，走「对象不存在不算失败」兜底，
//  因此可断言缓存侧行为；EK 删除失败路径（权限/进程错误）靠日志暴露与代码审查兜底
//
//  日期锚点：2026-10-26 09:00 为周一

import XCTest
import SwiftData
@testable import SwallowCalendar

@MainActor
final class RecurringMigrationTests: XCTestCase {

    private static let gateKey = "EventCacheService.recurringGroupsMigrationDone"

    override func setUpWithError() throws {
        // 每用例清门控，保证迁移函数可执行
        UserDefaults.standard.removeObject(forKey: Self.gateKey)
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removeObject(forKey: Self.gateKey)
    }

    /// 仅注册 CachedEvent 的内存 SwiftData 容器，注入 EventCacheService.shared
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: CachedEvent.self, configurations: config)
    }

    /// 本地时区日期构造
    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return Calendar.current.date(from: components)!
    }

    /// 构造旧版组实例行并落库（groupId/groupIndex 复刻旧模型多实例形态；
    /// 旧版应用创建的循环任务均为 user 分类，默认 .user 以匹配 syncEvents 删除判定）
    @discardableResult
    private func insertGroupInstance(
        into context: ModelContext,
        eventID: String,
        groupId: String,
        groupIndex: Int,
        startDate: Date,
        isCompleted: Bool = false,
        category: EventCategory = .user
    ) throws -> CachedEvent {
        let event = CachedEvent(
            eventID: eventID,
            title: "每天9点上班",
            startDate: startDate,
            endDate: startDate,
            isAllDay: false,
            calendarID: "test",
            calendarTitle: "测试日历",
            calendarColorHex: "#007AFF",
            category: category,
            isCompleted: isCompleted,
            groupId: groupId,
            groupIndex: groupIndex,
            recurrenceType: .daily
        )
        context.insert(event)
        try context.save()
        return event
    }

    private func fetchAll(_ context: ModelContext) throws -> [CachedEvent] {
        try context.fetch(FetchDescriptor<CachedEvent>())
    }

    // MARK: - 组合并

    /// 5 实例组（2 完成 3 未完成）→ 迁移 → 单条保留行 = 最早未完成实例，
    /// 完成历史 = 2 条已完成日期升序，groupId 置空，其余 4 行删除
    func testMigrationMergesGroupIntoSingleRecord() throws {
        let container = try makeContainer()
        let context = container.mainContext
        EventCacheService.shared.configure(with: container)
        let d1 = date(2026, 10, 26, 9, 0)
        let d2 = date(2026, 10, 27, 9, 0)
        let d3 = date(2026, 10, 28, 9, 0)
        let d4 = date(2026, 10, 29, 9, 0)
        let d5 = date(2026, 10, 30, 9, 0)
        try insertGroupInstance(into: context, eventID: "g-a1", groupId: "grp-1", groupIndex: 0, startDate: d1, isCompleted: true)
        try insertGroupInstance(into: context, eventID: "g-a2", groupId: "grp-1", groupIndex: 1, startDate: d2, isCompleted: true)
        try insertGroupInstance(into: context, eventID: "g-a3", groupId: "grp-1", groupIndex: 2, startDate: d3)
        try insertGroupInstance(into: context, eventID: "g-a4", groupId: "grp-1", groupIndex: 3, startDate: d4)
        try insertGroupInstance(into: context, eventID: "g-a5", groupId: "grp-1", groupIndex: 4, startDate: d5)

        EventCacheService.shared.migrateRecurringGroups(context: context, calendarService: CalendarService())

        let rows = try fetchAll(context)
        XCTAssertEqual(rows.count, 1, "迁移后整组应只剩 1 条单条记录")
        let keeper = try XCTUnwrap(rows.first)
        XCTAssertEqual(keeper.eventID, "g-a3", "保留行应为最早未完成实例")
        XCTAssertFalse(keeper.isCompleted)
        XCTAssertNil(keeper.groupId, "groupId 置空 = 迁移幂等标记")
        XCTAssertEqual(keeper.groupIndex, -1)
        XCTAssertEqual(keeper.recurrenceType, .daily, "周期规则保留")
        XCTAssertEqual(keeper.completedOccurrenceDates, [d1, d2], "已完成实例日期升序并入完成历史")
        XCTAssertEqual(keeper.startDate?.timeIntervalSince1970 ?? 0, d3.timeIntervalSince1970, accuracy: 0.001, "startDate 保持最早未完成实例日期")
    }

    // MARK: - 全完成组

    /// 全完成组：保留最晚一条已完成实例作单条（isCompleted=true，历史含全部日期）
    func testMigrationAllCompletedGroupKeepsLatestRow() throws {
        let container = try makeContainer()
        let context = container.mainContext
        EventCacheService.shared.configure(with: container)
        let d1 = date(2026, 10, 26, 9, 0)
        let d2 = date(2026, 10, 27, 9, 0)
        let d3 = date(2026, 10, 28, 9, 0)
        try insertGroupInstance(into: context, eventID: "g-b1", groupId: "grp-2", groupIndex: 0, startDate: d1, isCompleted: true)
        try insertGroupInstance(into: context, eventID: "g-b2", groupId: "grp-2", groupIndex: 1, startDate: d2, isCompleted: true)
        try insertGroupInstance(into: context, eventID: "g-b3", groupId: "grp-2", groupIndex: 2, startDate: d3, isCompleted: true)

        EventCacheService.shared.migrateRecurringGroups(context: context, calendarService: CalendarService())

        let rows = try fetchAll(context)
        XCTAssertEqual(rows.count, 1)
        let keeper = try XCTUnwrap(rows.first)
        XCTAssertEqual(keeper.eventID, "g-b3", "全完成组保留最晚一条已完成实例")
        XCTAssertTrue(keeper.isCompleted)
        XCTAssertEqual(keeper.completedOccurrenceDates, [d1, d2, d3])
        XCTAssertNil(keeper.groupId)
    }

    // MARK: - 门控

    /// 迁移成功后写 UserDefaults 门控；已门控再调用为 no-op（新预置组数据原地不动）
    func testMigrationGateWrittenAndShortCircuits() throws {
        let container = try makeContainer()
        let context = container.mainContext
        EventCacheService.shared.configure(with: container)
        let d1 = date(2026, 10, 26, 9, 0)
        let d2 = date(2026, 10, 27, 9, 0)
        try insertGroupInstance(into: context, eventID: "g-c1", groupId: "grp-3", groupIndex: 0, startDate: d1, isCompleted: true)
        try insertGroupInstance(into: context, eventID: "g-c2", groupId: "grp-3", groupIndex: 1, startDate: d2)

        EventCacheService.shared.migrateRecurringGroups(context: context, calendarService: CalendarService())
        XCTAssertTrue(UserDefaults.standard.bool(forKey: Self.gateKey), "全部组成功后应写门控")

        // 门控短路：再预置新组数据再调用，迁移不再执行
        let d3 = date(2026, 10, 28, 9, 0)
        try insertGroupInstance(into: context, eventID: "g-c3", groupId: "grp-9", groupIndex: 0, startDate: d3)
        EventCacheService.shared.migrateRecurringGroups(context: context, calendarService: CalendarService())
        let rows = try fetchAll(context)
        XCTAssertEqual(rows.count, 2, "门控后迁移不再执行，新组数据原地保留")
    }

    /// 无组数据（新库/非循环库）：直接写门控，避免每次启动全表扫描
    func testMigrationNoGroupsWritesGateImmediately() throws {
        let container = try makeContainer()
        let context = container.mainContext
        EventCacheService.shared.configure(with: container)

        EventCacheService.shared.migrateRecurringGroups(context: context, calendarService: CalendarService())

        XCTAssertTrue(UserDefaults.standard.bool(forKey: Self.gateKey))
        XCTAssertTrue(try fetchAll(context).isEmpty)
    }

    // MARK: - syncEvents 保全回归（plan step 10）

    /// syncEvents 全流程组合回归：预置 user 分类旧组 → syncEvents（无授权 EK 为空）
    /// → 迁移在开头自动触发单条化，user 行不参与删除判定，upsert 更新路径
    /// 不触碰 completedOccurrenceDatesJSON → 单条记录与完成历史完整保全
    func testSyncEventsPreservesMigratedSingleRecord() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        EventCacheService.shared.configure(with: container)
        let d1 = date(2026, 10, 26, 9, 0)
        let d2 = date(2026, 10, 27, 9, 0)
        let d3 = date(2026, 10, 28, 9, 0)
        try insertGroupInstance(into: context, eventID: "g-d1", groupId: "grp-4", groupIndex: 0, startDate: d1, isCompleted: true)
        try insertGroupInstance(into: context, eventID: "g-d2", groupId: "grp-4", groupIndex: 1, startDate: d2, isCompleted: true)
        try insertGroupInstance(into: context, eventID: "g-d3", groupId: "grp-4", groupIndex: 2, startDate: d3)

        let synced = await EventCacheService.shared.syncEvents(from: CalendarService(), calendars: [])
        XCTAssertTrue(synced, "无外部干扰下同步应成功")

        let rows = try fetchAll(context)
        XCTAssertEqual(rows.count, 1, "syncEvents 应自动触发迁移并保留单条记录")
        let keeper = try XCTUnwrap(rows.first)
        XCTAssertEqual(keeper.eventID, "g-d3", "保留行应为最早未完成实例")
        XCTAssertEqual(keeper.completedOccurrenceDates, [d1, d2], "完成历史不被同步清空")
        XCTAssertEqual(keeper.startDate?.timeIntervalSince1970 ?? 0, d3.timeIntervalSince1970, accuracy: 0.001, "startDate 不被同步改写")
        XCTAssertEqual(keeper.recurrenceType, .daily, "周期规则不被同步清除")
        XCTAssertNil(keeper.groupId, "迁移标记不因同步回退")
    }
}
