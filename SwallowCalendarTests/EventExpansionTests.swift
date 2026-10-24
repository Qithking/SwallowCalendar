//
//  EventExpansionTests.swift
//  SwallowCalendarTests
//
//  循环任务单条化 Behavior 3：getEvents 虚拟展开
//  单条循环任务在查询窗口内展开为 occurrence 实例（未落库），本体行被替换
//  Source: plan/recurring-task-single-record.md step 6
//
//  日期锚点：2026-10-24 为周六、10-25 周日、10-26 周一

import XCTest
import SwiftData
@testable import SwallowCalendar

@MainActor
final class EventExpansionTests: XCTestCase {

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

    /// 构造单条循环任务并落库
    @discardableResult
    private func insertRecurring(
        into context: ModelContext,
        eventID: String,
        startDate: Date,
        recurrenceType: RecurrenceType = .daily,
        skipHolidays: Bool = false,
        completed: [Date] = []
    ) throws -> CachedEvent {
        let event = CachedEvent(
            eventID: eventID,
            title: "循环任务",
            startDate: startDate,
            endDate: startDate,
            isAllDay: false,
            calendarID: "test",
            calendarTitle: "测试日历",
            calendarColorHex: "#007AFF",
            recurrenceType: recurrenceType
        )
        event.skipHolidays = skipHolidays
        event.completedOccurrenceDates = completed
        context.insert(event)
        try context.save()
        return event
    }

    /// 窗口 [day 00:00, day+days 00:00)
    private func dayWindow(_ year: Int, _ month: Int, _ day: Int, days: Int = 1) -> (Date, Date) {
        let start = date(year, month, day)
        let end = Calendar.current.date(byAdding: .day, value: days, to: start)!
        return (start, end)
    }

    // MARK: - 基础展开

    /// daily 循环任务在窗口内逐日展开，本体行被 occurrence 实例替换
    func testDailyRecurringExpandsEachDayInWindow() throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        try insertRecurring(
            into: container.mainContext,
            eventID: "rec-base",
            startDate: date(2026, 10, 26, 9, 0)
        )
        let (start, end) = dayWindow(2026, 10, 26, days: 3)
        let results = EventCacheService.shared.getEvents(from: start, to: end)

        // 窗口 3 天（26/27/28）→ 3 个 occurrence，本体行不再出现
        XCTAssertEqual(results.count, 3, "daily 循环任务应展开为窗口内每日一行")
        XCTAssertTrue(results.allSatisfy { $0.eventID.contains("|occ:") }, "展开行 eventID 应为复合格式")
        XCTAssertFalse(results.contains { $0.eventID == "rec-base" }, "本体行应被替换")
        // 复合 ID 可解析回本体与 occurrence
        for row in results {
            let parsed = CachedEvent.parseOccurrenceID(row.eventID)
            XCTAssertEqual(parsed?.baseID, "rec-base")
            XCTAssertNotNil(parsed?.occurrence)
        }
    }

    /// startDate 在窗口之前的循环任务，仅展开落入窗口内的 occurrence
    func testOccurrencesBeforeWindowNotReturned() throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        try insertRecurring(
            into: container.mainContext,
            eventID: "rec-past",
            startDate: date(2026, 10, 20, 9, 0)
        )
        let (start, end) = dayWindow(2026, 10, 26, days: 3)
        let results = EventCacheService.shared.getEvents(from: start, to: end)

        // 序列从 10/20 推进，窗口 26/27/28 三天命中
        XCTAssertEqual(results.count, 3, "窗口前开始的循环任务应只展开窗口内 occurrence")
        let days = results.compactMap {
            Calendar.current.dateComponents([.day], from: CachedEvent.parseOccurrenceID($0.eventID)?.occurrence ?? Date()).day
        }
        XCTAssertEqual(Set(days), [26, 27, 28])
    }

    /// startDate 在窗口之后的循环任务，窗口内无 occurrence（序列起点未到）
    func testOccurrenceAfterWindowNotReturned() throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        try insertRecurring(
            into: container.mainContext,
            eventID: "rec-future",
            startDate: date(2026, 11, 2, 9, 0)
        )
        let (start, end) = dayWindow(2026, 10, 26, days: 3)
        let results = EventCacheService.shared.getEvents(from: start, to: end)
        XCTAssertEqual(results.count, 0, "下一次 occurrence 未进窗口前不应出现")
    }

    // MARK: - 完成历史行

    /// 完成历史中的日期在窗口内 → 产出已完成实例；序列行保持未完成
    func testCompletedHistoryRowAppearsCompleted() throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        // 10/26 已完成并推进：完成历史含 10/26，startDate 已推进到 10/27
        try insertRecurring(
            into: container.mainContext,
            eventID: "rec-hist",
            startDate: date(2026, 10, 27, 9, 0),
            completed: [date(2026, 10, 26, 9, 0)]
        )
        let (start, end) = dayWindow(2026, 10, 26, days: 3)
        let results = EventCacheService.shared.getEvents(from: start, to: end)

        // 窗口 [10/26, 10/29)：10/26 历史行 + 10/27、10/28 序列行
        XCTAssertEqual(results.count, 3, "窗口内应有 10/26 历史行 + 10/27、10/28 序列行")
        let historyRows = results.filter { $0.isCompleted }
        let upcomingRows = results.filter { !$0.isCompleted }
        XCTAssertEqual(historyRows.count, 1)
        XCTAssertEqual(upcomingRows.count, 2)
        // 历史行 occurrence = 10/26，序列行 occurrence 从 10/27 起
        XCTAssertEqual(
            CachedEvent.parseOccurrenceID(historyRows.first?.eventID ?? "")?.occurrence,
            date(2026, 10, 26, 9, 0)
        )
        XCTAssertEqual(
            CachedEvent.parseOccurrenceID(upcomingRows.first?.eventID ?? "")?.occurrence,
            date(2026, 10, 27, 9, 0)
        )
    }

    // MARK: - 跳过节假日（v3 语义：显示层静默过滤）

    /// skipHolidays=true：落周末的 occurrence 静默跳过（无节假日数据时周末规则仍生效）
    func testSkipHolidaysSilentlySkipsWeekend() throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        // 10/24 周六起，skipHolidays=true：24(六)/25(日) 跳过，26(一) 显示
        try insertRecurring(
            into: container.mainContext,
            eventID: "rec-skip",
            startDate: date(2026, 10, 24, 9, 0),
            skipHolidays: true
        )
        let (start, end) = dayWindow(2026, 10, 24, days: 3)
        let results = EventCacheService.shared.getEvents(from: start, to: end)

        XCTAssertEqual(results.count, 1, "周末 occurrence 应被静默跳过")
        XCTAssertEqual(
            CachedEvent.parseOccurrenceID(results.first?.eventID ?? "")?.occurrence,
            date(2026, 10, 26, 9, 0),
            "仅周一 occurrence 保留"
        )
    }

    /// skipHolidays=false 对照：周末 occurrence 照常显示
    func testNoSkipShowsWeekendOccurrences() throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        try insertRecurring(
            into: container.mainContext,
            eventID: "rec-noskip",
            startDate: date(2026, 10, 24, 9, 0)
        )
        let (start, end) = dayWindow(2026, 10, 24, days: 3)
        let results = EventCacheService.shared.getEvents(from: start, to: end)
        XCTAssertEqual(results.count, 3, "未勾选跳过时周末照常显示")
    }

    // MARK: - 普通任务回归

    /// 普通任务（recurrenceType=none）行为零变化
    func testNonRecurringRowsUnchanged() throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        let context = container.mainContext
        let normal = CachedEvent(
            eventID: "normal-1",
            title: "普通任务",
            startDate: date(2026, 10, 26, 10, 0),
            endDate: date(2026, 10, 26, 10, 0),
            isAllDay: false,
            calendarID: "test",
            calendarTitle: "测试日历",
            calendarColorHex: "#007AFF"
        )
        context.insert(normal)
        try context.save()

        let (start, end) = dayWindow(2026, 10, 26)
        let results = EventCacheService.shared.getEvents(from: start, to: end)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].eventID, "normal-1", "普通行原样返回，无展开")
    }

    // MARK: - 展开上限护栏

    /// 极久远 startDate 的展开在迭代上限处中止（防死循环/内存爆炸）
    func testExpansionCapPreventsRunaway() throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        try insertRecurring(
            into: container.mainContext,
            eventID: "rec-ancient",
            startDate: date(1926, 1, 1, 9, 0)
        )
        let (start, end) = dayWindow(2026, 10, 24)
        let results = EventCacheService.shared.getEvents(from: start, to: end)
        // 上限护栏：产出实例数受控，不因历史跨度爆炸
        XCTAssertLessThanOrEqual(results.count, 4001)
    }
}
