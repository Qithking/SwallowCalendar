//
//  RecurringEditDeleteTests.swift
//  SwallowCalendarTests
//
//  循环任务单条化 Behavior 6：编辑/删除链路
//  - 编辑即改整条：周期→1次清完成历史、startDate 不动；复合 ID 编辑回查本体
//  - 删除即删整条：复合 ID 删除回查本体（应用 1 条 + EK 1 条）
//  Source: plan/recurring-task-single-record.md step 7/8
//
//  测试环境 EventKit 无授权 → deleteEvent 走「EK 对象不存在不算失败」兜底，
//  仅删缓存，因此可断言缓存侧行为；updateEventRecurrence 纯缓存操作可直接断言
//
//  日期锚点：2026-10-26 09:00 为周一

import XCTest
import SwiftData
@testable import SwallowCalendar

@MainActor
final class RecurringEditDeleteTests: XCTestCase {

    private var calendarService: CalendarService!

    override func setUpWithError() throws {
        calendarService = CalendarService()
    }

    override func tearDownWithError() throws {
        calendarService = nil
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

    /// 构造单条循环任务并落库，返回（缓存对象, baseID）
    @discardableResult
    private func insertRecurring(
        into context: ModelContext,
        eventID: String,
        startDate: Date,
        recurrenceType: RecurrenceType = .daily,
        completionHistory: [Date] = []
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
            recurrenceType: recurrenceType
        )
        // 完成历史经计算属性 setter 写入（维护 JSON 真源）
        if !completionHistory.isEmpty {
            event.completedOccurrenceDates = completionHistory
        }
        context.insert(event)
        try context.save()
        return event
    }

    /// occurrence 复合 ID 快捷构造
    private func occID(_ baseID: String, _ occurrence: Date) -> String {
        CachedEvent.makeOccurrenceID(baseID: baseID, occurrence: occurrence)
    }

    // MARK: - 周期 → 1次

    /// 周期改 1 次：完成历史清空（普通任务只有 isCompleted 单状态）、startDate 不动
    func testRecurrenceToNoneClearsCompletionHistoryKeepsStartDate() throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        let d0 = date(2026, 10, 26, 9, 0)
        let cached = try insertRecurring(
            into: container.mainContext,
            eventID: "rec-base",
            startDate: d0,
            completionHistory: [d0]
        )

        calendarService.updateEventRecurrence(eventID: "rec-base", newRecurrenceType: .none)

        XCTAssertFalse(cached.isCompleted)
        XCTAssertEqual(cached.completedOccurrenceDates, [])
        XCTAssertEqual(cached.startDate?.timeIntervalSince1970 ?? 0, d0.timeIntervalSince1970, accuracy: 0.001)
    }

    // MARK: - 改周期类型

    /// daily 改 weekly：类型更新、完成历史保留、startDate 不动（下一次 occurrence 由查询链从 startDate 以新周期推进）
    func testChangeRecurrenceTypeKeepsHistoryAndStartDate() throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        let d0 = date(2026, 10, 26, 9, 0)
        let cached = try insertRecurring(
            into: container.mainContext,
            eventID: "rec-base",
            startDate: d0,
            completionHistory: [d0]
        )

        calendarService.updateEventRecurrence(eventID: "rec-base", newRecurrenceType: .weekly)

        XCTAssertEqual(cached.recurrenceType, .weekly)
        XCTAssertEqual(cached.completedOccurrenceDates, [d0])
        XCTAssertEqual(cached.startDate?.timeIntervalSince1970 ?? 0, d0.timeIntervalSince1970, accuracy: 0.001)
    }

    // MARK: - 复合 ID 分流

    /// 从 occurrence 虚拟行发起周期编辑（复合 ID）：回查本体改整条
    func testUpdateRecurrenceViaOccurrenceIDRewritesBase() throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        let d0 = date(2026, 10, 26, 9, 0)
        let cached = try insertRecurring(
            into: container.mainContext,
            eventID: "rec-base",
            startDate: d0
        )

        calendarService.updateEventRecurrence(eventID: occID("rec-base", d0), newRecurrenceType: .none)

        XCTAssertEqual(cached.recurrenceType, .none)
        XCTAssertEqual(cached.completedOccurrenceDates, [])
    }

    /// 从 occurrence 虚拟行发起删除（复合 ID）：删除整条本体记录
    func testDeleteEventViaOccurrenceIDDeletesBaseRecord() throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        let d0 = date(2026, 10, 26, 9, 0)
        try insertRecurring(
            into: container.mainContext,
            eventID: "rec-base",
            startDate: d0
        )

        try calendarService.deleteEvent(eventID: occID("rec-base", d0))

        // 本体记录被删（应用侧删整条；EK 侧对象不存在走兜底，测试环境仅验证缓存）
        var descriptor = FetchDescriptor<CachedEvent>(predicate: #Predicate { $0.eventID == "rec-base" })
        descriptor.fetchLimit = 1
        let remaining = try container.mainContext.fetch(descriptor)
        XCTAssertTrue(remaining.isEmpty)
    }
}
