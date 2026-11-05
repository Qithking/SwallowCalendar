//
//  RecurringToSingleConversionTests.swift
//  SwallowCalendarTests
//
//  BUG-21 用户口径回归：循环任务改为单次时
//  ① 已完成历史保留（已办列表可见）；
//  ② 未来未完成实例全部去除（不再展开、不再提醒）。
//  数据侧真源：completedOccurrenceDatesJSON 保留、originStartDate 清空。
//

import XCTest
import SwiftData
@testable import SwallowCalendar

@MainActor
final class RecurringToSingleConversionTests: XCTestCase {

    private var container: ModelContainer!

    override func setUp() async throws {
        try await super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: CachedEvent.self, configurations: config)
        EventCacheService.shared.configure(with: container)
    }

    private func date(_ day: Int, hour: Int = 9) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 10
        components.day = day
        components.hour = hour
        return Calendar.current.date(from: components)!
    }

    private func occID(_ baseID: String, _ occurrence: Date) -> String {
        CachedEvent.makeOccurrenceID(baseID: baseID, occurrence: occurrence)
    }

    @discardableResult
    private func insertRecurring(eventID: String, startDate: Date) throws -> CachedEvent {
        let cached = CachedEvent(
            eventID: eventID,
            title: "循环任务",
            startDate: startDate,
            endDate: startDate,
            isAllDay: false,
            calendarID: "test",
            calendarTitle: "测试",
            calendarColorHex: "#FF9500",
            category: .user,
            isReminder: false,
            isCompleted: false,
            priority: 0,
            recurrenceType: .daily
        )
        cached.originStartDate = startDate
        container.mainContext.insert(cached)
        try container.mainContext.save()
        return cached
    }

    private func visibleEvents(from start: Date, to end: Date) -> [CachedEvent] {
        EventCacheService.shared.getEvents(from: start, to: end, includeNoDateReminders: true)
    }

    /// 场景①：3 期已完成 + 未来 2 期 → 改单次后已办仍 3 期，未来不再出现
    func testConvertWithThreeCompletedKeepsHistoryAndDropsFuture() async throws {
        let d0 = date(26), d1 = date(27), d2 = date(28), d3 = date(29)
        let cached = try insertRecurring(eventID: "rec-3done", startDate: d0)

        for occ in [d0, d1, d2] {
            await CalendarService.shared.toggleEventCompleted(eventID: occID("rec-3done", occ), isCompleted: true)
        }
        XCTAssertEqual(cached.completedOccurrenceDates, [d0, d1, d2])
        XCTAssertEqual(cached.startDate?.timeIntervalSince1970 ?? 0, d3.timeIntervalSince1970, accuracy: 0.001)

        CalendarService.shared.updateEventRecurrence(eventID: "rec-3done", newRecurrenceType: .none)

        // 数据侧：历史保留、未来展开依据清除
        XCTAssertEqual(cached.recurrenceType, .none)
        XCTAssertEqual(cached.completedOccurrenceDates, [d0, d1, d2], "改单次不得清空完成历史")
        XCTAssertNil(cached.originStartDate, "必须清除未来展开依据")

        // 已办可见：历史 3 期 + 游标当期为 1 条未完成，共 4 行
        let fullWindow = visibleEvents(from: d0, to: date(31))
        XCTAssertEqual(fullWindow.count, 4)
        XCTAssertEqual(fullWindow.filter(\.isCompleted).count, 3, "已办列表仍应显示 3 期历史")
        XCTAssertEqual(
            fullWindow.filter(\.isCompleted).compactMap(\.startDate).sorted(),
            [d0, d1, d2]
        )

        // 未来去除：只覆盖 d4 之后的窗口不得产出任何行（不再按天展开）
        let futureOnly = visibleEvents(from: d3.addingTimeInterval(86400), to: date(31))
        XCTAssertTrue(futureOnly.isEmpty, "改单次后未来实例必须全部去除")
    }

    /// 场景②：无任何完成 → 干净转为单次（仅剩游标一条，无历史行、无未来展开）
    func testConvertWithoutHistoryBecomesCleanSingle() throws {
        let d0 = date(26)
        let cached = try insertRecurring(eventID: "rec-nodone", startDate: d0)

        CalendarService.shared.updateEventRecurrence(eventID: "rec-nodone", newRecurrenceType: .none)

        XCTAssertEqual(cached.recurrenceType, .none)
        XCTAssertNil(cached.completedOccurrenceDatesJSON)
        XCTAssertNil(cached.originStartDate)

        let current = visibleEvents(from: d0, to: date(27))
        XCTAssertEqual(current.count, 1, "只保留任务本体一条")
        XCTAssertFalse(current[0].isCompleted)

        let futureOnly = visibleEvents(from: date(27), to: date(31))
        XCTAssertTrue(futureOnly.isEmpty, "不再展开未来实例")
    }

    /// 场景③：已完成后撤销再改单次 → 历史随撤销正确变化（撤销期次不进入已办）
    func testConvertAfterUndoKeepsOnlyRemainingHistory() async throws {
        let d0 = date(26), d1 = date(27), d2 = date(28), d3 = date(29)
        let cached = try insertRecurring(eventID: "rec-undo", startDate: d0)

        for occ in [d0, d1, d2] {
            await CalendarService.shared.toggleEventCompleted(eventID: occID("rec-undo", occ), isCompleted: true)
        }
        // 撤销第 2 期（仍为循环态）
        await CalendarService.shared.toggleEventCompleted(eventID: occID("rec-undo", d1), isCompleted: false)
        XCTAssertEqual(cached.completedOccurrenceDates, [d0, d2])
        XCTAssertEqual(cached.startDate?.timeIntervalSince1970 ?? 0, d3.timeIntervalSince1970, accuracy: 0.001)

        CalendarService.shared.updateEventRecurrence(eventID: "rec-undo", newRecurrenceType: .none)

        XCTAssertEqual(cached.completedOccurrenceDates, [d0, d2], "撤销后的历史必须原样保留")
        let fullWindow = visibleEvents(from: d0, to: date(31))
        XCTAssertEqual(fullWindow.filter(\.isCompleted).compactMap(\.startDate).sorted(), [d0, d2])
        XCTAssertEqual(fullWindow.filter(\.isCompleted).count, 2)
    }

    /// 场景④（BUG-21 回归）：转单次后完成「游标行」必须生效——
    /// 未完成游标行须产出本体 eventID（走 toggleEventCompleted 本体路径写
    /// base.isCompleted），而非复合 ID（会被 toggleRecurringOccurrence 的
    /// .none guard 静默拒绝，导致任务永远无法完成）
    func testCompleteCursorRowAfterConversionWritesBaseCompleted() async throws {
        let d0 = date(26), d1 = date(27), d2 = date(28)
        let cached = try insertRecurring(eventID: "rec-convert-done", startDate: d0)

        // 完成 1 期后转单次：游标推进到 d1，历史保留 d0
        await CalendarService.shared.toggleEventCompleted(eventID: occID("rec-convert-done", d0), isCompleted: true)
        CalendarService.shared.updateEventRecurrence(eventID: "rec-convert-done", newRecurrenceType: .none)
        XCTAssertEqual(cached.recurrenceType, .none)

        // 未完成游标行必须是本体 ID，而非复合 occurrence ID
        let window = visibleEvents(from: d1, to: date(29))
        XCTAssertEqual(window.count, 1, "转单次后只应剩游标本体一条未完成行")
        XCTAssertEqual(window[0].eventID, "rec-convert-done", "游标行必须是本体 eventID（完成点击走本体路径）")
        XCTAssertFalse(window[0].isCompleted)

        // 完成点击生效：写入 base.isCompleted，重载后未完成行消失
        await CalendarService.shared.toggleEventCompleted(eventID: window[0].eventID, isCompleted: true)
        XCTAssertTrue(cached.isCompleted, "转单次后的完成点击必须写入本体 isCompleted")

        let after = visibleEvents(from: d1, to: date(29))
        XCTAssertTrue(after.isEmpty, "本体完成后窗口内不应再有未完成行")
        // 已办只有历史复合行 1 条——本体完成后特例不再产出本体行
        XCTAssertEqual(visibleEvents(from: d0, to: date(29)).filter(\.isCompleted).count, 1)
    }
}
