//
//  CalendarGridRecurringDisplayTests.swift
//  SwallowCalendarTests
//
//  月历格子循环任务显示回归测试
//  bug: calendar-grid-recurring-invisible——月视图 @Query 直查主表，
//  循环任务 base.startDate 为过去首实例，未来 occurrence 未落库不可见；
//  期望：循环任务在月窗口内所有日期可见，勾选智能跳过节假日的休日实例
//  仍显示并保留「已智能跳过」标识（月历无顺延语义）
//

import XCTest
import SwiftData
@testable import SwallowCalendar

@MainActor
final class CalendarGridRecurringDisplayTests: XCTestCase {

    /// 仅注册 CachedEvent 的内存 SwiftData 容器，注入 EventCacheService.shared
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: CachedEvent.self, configurations: config)
    }

    /// 构造循环任务并落库
    private func insertRecurring(
        into context: ModelContext,
        eventID: String,
        startDate: Date,
        skipHolidays: Bool = false
    ) throws {
        let event = CachedEvent(
            eventID: eventID,
            title: "循环任务",
            startDate: startDate,
            endDate: startDate.addingTimeInterval(3600),
            isAllDay: false,
            calendarID: "test",
            calendarTitle: "测试日历",
            calendarColorHex: "#007AFF",
            category: .user,
            recurrenceType: .daily
        )
        event.skipHolidays = skipHolidays
        context.insert(event)
        try context.save()
    }

    /// 本地时区日期构造
    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 9) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return Calendar.current.date(from: components)!
    }

    /// 循环任务 base 在过去（7 天前），月视图合并结果必须包含窗口内未来实例
    ///（base 本体行被展开实例替换，与 getEvents 语义一致）
    func testMergedDisplayEventsIncludesFutureOccurrences() throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        let context = container.mainContext
        // 2026-10-26 周一为「今日」锚点：base 从 7 天前（10/19 周一）开始
        try insertRecurring(into: context, eventID: "rec-base", startDate: date(2026, 10, 19))

        let all = try context.fetch(FetchDescriptor<CachedEvent>())
        let merged = EventCacheService.shared.mergedDisplayEvents(
            from: all,
            windowStart: date(2026, 10, 26),
            windowEnd: date(2026, 10, 29),
            context: context
        )

        // 窗口 26/27/28 三天 → 3 个未来实例，本体行不再出现
        XCTAssertEqual(merged.count, 3, "月视图合并结果应包含窗口内每日循环实例")
        XCTAssertFalse(merged.contains { $0.eventID == "rec-base" }, "循环 base 本体行应被展开实例替换")
        XCTAssertTrue(merged.contains { event in
            Calendar.current.isDate(event.startDate ?? .distantPast, inSameDayAs: date(2026, 10, 26))
        }, "今日（10/26）格子应能看到循环任务实例")
    }

    /// 勾选智能跳过节假日的循环任务：休日实例仍产出（月历无顺延，
    /// 原休日格显示 + 「已智能跳过」标识由 skippedEventIDs 机制识别）
    func testMergedDisplayEventsKeepsHolidaySkippedInstance() throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        let context = container.mainContext
        // 2026-10-24 周六起 skipHolidays=true：24(六)/25(日) 为休日
        try insertRecurring(into: context, eventID: "rec-holiday", startDate: date(2026, 10, 24), skipHolidays: true)

        let all = try context.fetch(FetchDescriptor<CachedEvent>())
        let merged = EventCacheService.shared.mergedDisplayEvents(
            from: all,
            windowStart: date(2026, 10, 24),
            windowEnd: date(2026, 10, 27),
            context: context
        )

        // 月历语义：24/25 休日实例仍显示（带标识），26 周一正常显示
        XCTAssertEqual(merged.count, 3, "月视图合并应保留休日实例（无顺延，标识由格子渲染层处理）")
        let saturday = merged.first { event in
            Calendar.current.isDate(event.startDate ?? .distantPast, inSameDayAs: date(2026, 10, 24))
        }
        XCTAssertNotNil(saturday, "周六休日实例应存在于月视图合并结果")
        XCTAssertEqual(saturday?.skipHolidays, true, "休日实例应保留 skipHolidays 标记供标识机制识别")
    }

    /// 对照：getEvents（列表路径）默认仍静默跳过休日实例——列表语义不因月视图修复而变
    func testGetEventsStillSkipsHolidayOccurrencesByDefault() throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        let context = container.mainContext
        try insertRecurring(into: context, eventID: "rec-list", startDate: date(2026, 10, 24), skipHolidays: true)

        let list = EventCacheService.shared.getEvents(from: date(2026, 10, 24), to: date(2026, 10, 27))
        XCTAssertEqual(list.count, 1, "列表路径默认语义：24/25 休日静默跳过，仅 26(一) 显示")
    }
}
