//
//  RecurringCompletionTests.swift
//  SwallowCalendarTests
//
//  循环任务单条化 Behavior 4：完成链路 — occurrence 级完成/撤销/幂等（缓存侧行为）
//  复合 ID 进入 toggleEventCompleted 后：完成=记录历史并推进 startDate，
//  不再整条 isCompleted、不再追加新实例
//  Source: plan/recurring-task-single-record.md step 5
//
//  测试环境 EventKit 中无对应记录 → 走「对象不存在不算失败」兜底路径，
//  EK 侧跳过、缓存侧照写，因此可断言缓存侧行为
//
//  日期锚点：2026-10-26 09:00 为周一

import XCTest
import SwiftData
@testable import SwallowCalendar

@MainActor
final class RecurringCompletionTests: XCTestCase {

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
        recurrenceType: RecurrenceType = .daily
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
        context.insert(event)
        try context.save()
        return event
    }

    /// occurrence 复合 ID 快捷构造
    private func occID(_ baseID: String, _ occurrence: Date) -> String {
        CachedEvent.makeOccurrenceID(baseID: baseID, occurrence: occurrence)
    }

    // MARK: - 完成 occurrence

    /// 完成 occurrence d0：历史追加 d0、startDate 推进到 d1、isCompleted 保持 false
    func testCompleteOccurrenceAppendsHistoryAndAdvancesStartDate() async throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        let d0 = date(2026, 10, 26, 9, 0)
        let d1 = Calendar.current.date(byAdding: .day, value: 1, to: d0)!
        let cached = try insertRecurring(
            into: container.mainContext,
            eventID: "rec-base",
            startDate: d0
        )

        await calendarService.toggleEventCompleted(
            eventID: occID("rec-base", d0),
            isCompleted: true
        )

        // 历史记录该 occurrence，整条保持未完成
        XCTAssertEqual(cached.completedOccurrenceDates, [d0])
        XCTAssertFalse(cached.isCompleted)
        // startDate 推进到下一次 occurrence
        XCTAssertEqual(cached.startDate?.timeIntervalSince1970 ?? 0, d1.timeIntervalSince1970, accuracy: 0.001)
    }

    /// 提醒类型（isReminder=true）走同一缓存侧逻辑
    func testCompleteReminderOccurrenceAdvancesCache() async throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        let d0 = date(2026, 10, 26, 9, 0)
        let d1 = Calendar.current.date(byAdding: .day, value: 1, to: d0)!
        let cached = try insertRecurring(
            into: container.mainContext,
            eventID: "rec-rem",
            startDate: d0
        )

        await calendarService.toggleEventCompleted(
            eventID: occID("rec-rem", d0),
            isCompleted: true,
            isReminder: true
        )

        XCTAssertEqual(cached.completedOccurrenceDates, [d0])
        XCTAssertFalse(cached.isCompleted)
        XCTAssertEqual(cached.startDate?.timeIntervalSince1970 ?? 0, d1.timeIntervalSince1970, accuracy: 0.001)
    }

    // MARK: - 幂等

    /// 重复完成同一 occurrence：历史不重复、startDate 不二次推进
    func testCompleteOccurrenceIsIdempotent() async throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        let d0 = date(2026, 10, 26, 9, 0)
        let d1 = Calendar.current.date(byAdding: .day, value: 1, to: d0)!
        let cached = try insertRecurring(
            into: container.mainContext,
            eventID: "rec-base",
            startDate: d0
        )

        await calendarService.toggleEventCompleted(eventID: occID("rec-base", d0), isCompleted: true)
        await calendarService.toggleEventCompleted(eventID: occID("rec-base", d0), isCompleted: true)

        XCTAssertEqual(cached.completedOccurrenceDates, [d0])
        XCTAssertEqual(cached.startDate?.timeIntervalSince1970 ?? 0, d1.timeIntervalSince1970, accuracy: 0.001)
    }

    // MARK: - 撤销完成

    /// 撤销完成：历史移除该日期，startDate 不回退
    func testUncompleteOccurrenceRemovesHistoryKeepsAdvancedStartDate() async throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        let d0 = date(2026, 10, 26, 9, 0)
        let d1 = Calendar.current.date(byAdding: .day, value: 1, to: d0)!
        let cached = try insertRecurring(
            into: container.mainContext,
            eventID: "rec-base",
            startDate: d0
        )

        await calendarService.toggleEventCompleted(eventID: occID("rec-base", d0), isCompleted: true)
        await calendarService.toggleEventCompleted(eventID: occID("rec-base", d0), isCompleted: false)

        // 历史移除，序列不回退（撤销语义：仅移除历史日期）
        XCTAssertEqual(cached.completedOccurrenceDates, [])
        XCTAssertEqual(cached.startDate?.timeIntervalSince1970 ?? 0, d1.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertFalse(cached.isCompleted)
    }

    // MARK: - 历史 occurrence

    /// 完成 startDate 之前的历史 occurrence：只记历史，不推进 startDate
    func testCompleteHistoricalOccurrenceDoesNotAdvanceStartDate() async throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        let d0 = date(2026, 10, 26, 9, 0)
        // 本体 startDate 已推进到 d2，补完成历史 d0
        let d2 = Calendar.current.date(byAdding: .day, value: 2, to: d0)!
        let cached = try insertRecurring(
            into: container.mainContext,
            eventID: "rec-base",
            startDate: d2
        )

        await calendarService.toggleEventCompleted(eventID: occID("rec-base", d0), isCompleted: true)

        // 只追加历史，startDate 保持 d2
        XCTAssertEqual(cached.completedOccurrenceDates, [d0])
        XCTAssertEqual(cached.startDate?.timeIntervalSince1970 ?? 0, d2.timeIntervalSince1970, accuracy: 0.001)
    }
}
