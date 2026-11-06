//
//  MonthWindowPredicateTests.swift
//  SwallowCalendarTests
//
//  月历窗口谓词回归测试
//  bug: month-switch-recurring-invisible——月视图 @Query 用纯窗口重叠谓词，
//  循环 base 行（startDate=过去首实例）与下月窗口不重叠被排除，切月后
//  mergedDisplayEvents 无行可展开 → 新月份无循环实例；
//  期望：月窗口谓词对循环行豁免（始终包含），普通行仍按窗口重叠过滤
//

import XCTest
import SwiftData
@testable import SwallowCalendar

@MainActor
final class MonthWindowPredicateTests: XCTestCase {

    /// 仅注册 CachedEvent 的内存 SwiftData 容器
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: CachedEvent.self, configurations: config)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 9) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return Calendar.current.date(from: components)!
    }

    private func insert(
        into context: ModelContext,
        eventID: String,
        startDate: Date,
        recurrenceType: RecurrenceType
    ) throws {
        let event = CachedEvent(
            eventID: eventID,
            title: "测试",
            startDate: startDate,
            endDate: startDate.addingTimeInterval(3600),
            isAllDay: false,
            calendarID: "test",
            calendarTitle: "测试日历",
            calendarColorHex: "#007AFF",
            category: .user,
            recurrenceType: recurrenceType
        )
        context.insert(event)
        try context.save()
    }

    /// RCA 证据锁定（永久 pass）：纯窗口重叠谓词在下月窗口排除过去 base 行
    /// ——这正是切换月份后循环任务消失的断链点
    func testPureWindowPredicateExcludesPastRecurringBase() throws {
        let container = try makeContainer()
        let context = container.mainContext
        try insert(into: context, eventID: "rec-base", startDate: date(2026, 10, 19), recurrenceType: .daily)

        // 2026 年 11 月窗口（11/1 前扩 7 天 ~ 11/1+38 天）
        let windowStart = date(2026, 10, 25)
        let windowEnd = date(2026, 12, 9)
        let distantPast = Date.distantPast
        let distantFuture = Date.distantFuture
        let pureWindow = #Predicate<CachedEvent> { event in
            (event.startDate ?? distantPast) < windowEnd
                && (event.endDate ?? distantFuture) > windowStart
        }
        let fetched = try context.fetch(FetchDescriptor<CachedEvent>(predicate: pureWindow))
        XCTAssertFalse(fetched.contains { $0.eventID == "rec-base" },
                       "纯窗口谓词应排除过去 base 行（bug 断链证据，锁定语义）")
    }

    /// 月窗口谓词：循环行豁免窗口过滤（下月窗口仍含 base，供展开），普通行按窗口过滤
    func testMonthWindowPredicateExemptsRecurringRows() throws {
        let container = try makeContainer()
        let context = container.mainContext
        try insert(into: context, eventID: "rec-base", startDate: date(2026, 10, 19), recurrenceType: .daily)
        try insert(into: context, eventID: "past-normal", startDate: date(2026, 10, 19), recurrenceType: .none)
        try insert(into: context, eventID: "nov-normal", startDate: date(2026, 11, 15), recurrenceType: .none)

        // 2026 年 11 月窗口
        let predicate = CachedEvent.monthWindowPredicate(windowStart: date(2026, 10, 25), windowEnd: date(2026, 12, 9))
        let fetched = try context.fetch(FetchDescriptor<CachedEvent>(predicate: predicate))

        XCTAssertTrue(fetched.contains { $0.eventID == "rec-base" },
                      "循环 base 行应豁免窗口过滤，切月后仍可供展开")
        XCTAssertFalse(fetched.contains { $0.eventID == "past-normal" },
                       "过去普通行不应命中下月窗口")
        XCTAssertTrue(fetched.contains { $0.eventID == "nov-normal" },
                      "窗口内普通行应正常命中")
    }

    /// BUG-21 回归：循环改单次（recurrenceType=.none）后保留完成历史，
    /// 游标 startDate 已推进到历史窗口之外；月历 @Query 必须仍命中该本体行，
    /// 否则 mergedDisplayEvents 无从展开，历史期次在月历永久不可见
    func testMonthWindowPredicateKeepsConvertedSingleWithHistory() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let history = [date(2026, 10, 20), date(2026, 10, 21), date(2026, 10, 22)]
        let cursor = date(2026, 11, 20)
        let event = CachedEvent(
            eventID: "converted-history",
            title: "转单次任务",
            startDate: cursor,
            endDate: cursor.addingTimeInterval(3600),
            isAllDay: false,
            calendarID: "test",
            calendarTitle: "测试日历",
            calendarColorHex: "#007AFF",
            category: .user,
            recurrenceType: .none
        )
        event.completedOccurrenceDates = history
        context.insert(event)
        try context.save()

        // 2026 年 10 月窗口：与历史期次重叠，但与游标（11/20）不重叠
        let windowStart = date(2026, 9, 24)
        let windowEnd = date(2026, 11, 8)
        let predicate = CachedEvent.monthWindowPredicate(windowStart: windowStart, windowEnd: windowEnd)
        let fetched = try context.fetch(FetchDescriptor<CachedEvent>(predicate: predicate))
        XCTAssertTrue(fetched.contains { $0.eventID == "converted-history" },
                      "转单次保留历史的本体行必须在历史月份窗口命中（游标在窗外）")

        let merged = EventCacheService.shared.mergedDisplayEvents(
            from: fetched,
            windowStart: windowStart,
            windowEnd: windowEnd,
            context: context
        )
        XCTAssertEqual(
            merged.filter(\.isCompleted).compactMap(\.startDate).sorted(),
            history,
            "月历展开必须产出 3 期已完成历史"
        )
    }
}
