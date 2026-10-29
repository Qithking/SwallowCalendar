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
        completed: [Date] = [],
        originStartDate: Date? = nil
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
        event.originStartDate = originStartDate
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

    // MARK: - 展开起点对齐（bug: reminder-starved-by-badge-expansion）

    /// 古老锚点每天循环应展开到当前窗口（对齐起点消除锚点→窗口间无产出推进）：
    /// 修复前从 1926 逐次推进 4000 次截断在 1936 年附近，窗口内 0 实例（RED）
    func testAncientDailyAnchorExpandsToCurrentWindow() throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        try insertRecurring(
            into: container.mainContext,
            eventID: "rec-ancient-daily",
            startDate: date(1926, 1, 1, 9, 0)
        )
        let (start, end) = dayWindow(2026, 10, 24)
        let results = EventCacheService.shared.getEvents(from: start, to: end)

        XCTAssertEqual(results.count, 1, "古老锚点每天循环应在窗口内展开当天实例")
        XCTAssertEqual(
            CachedEvent.parseOccurrenceID(results.first?.eventID ?? "")?.occurrence,
            date(2026, 10, 24, 9, 0),
            "对齐跳转后的相位必须与逐次推进序列完全一致"
        )
    }

    /// 古老锚点每周循环同理（修复前 4000 周截断在 2002 年附近）
    func testAncientWeeklyAnchorExpandsToCurrentWindow() throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        try insertRecurring(
            into: container.mainContext,
            eventID: "rec-ancient-weekly",
            startDate: date(1926, 1, 1, 9, 0),
            recurrenceType: .weekly
        )
        let (start, end) = dayWindow(2026, 10, 24, days: 7)
        let results = EventCacheService.shared.getEvents(from: start, to: end)

        XCTAssertEqual(results.count, 1, "古老锚点每周循环应在 7 天窗口内展开 1 个周实例")
        // 相位时间保持锚点的 09:00（对齐不漂移）；具体周几由 1926-01-01 的 weekday 决定
        let occurrence = CachedEvent.parseOccurrenceID(results.first?.eventID ?? "")?.occurrence
        XCTAssertEqual(Calendar.current.component(.hour, from: occurrence ?? Date()), 9, "对齐跳转不得漂移相位时间")
        if let occurrence {
            XCTAssertTrue(occurrence >= start && occurrence < end, "周实例应落在窗口内")
        }
    }

    /// 古老锚点 + 完成历史：窗口内完成行（① 独家）与未完成行（② 展开）共 3 行，
    /// 修复前 ② 截断仅剩完成行（RED），修复后相位精确不重复
    func testAncientAnchorKeepsCompletionHistoryAndPhases() throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        try insertRecurring(
            into: container.mainContext,
            eventID: "rec-ancient-completed",
            startDate: date(1926, 1, 1, 9, 0),
            completed: [date(2026, 10, 23, 9, 0)]
        )
        let (start, end) = dayWindow(2026, 10, 23, days: 3)
        let results = EventCacheService.shared.getEvents(from: start, to: end)

        XCTAssertEqual(results.count, 3, "窗口 [10-23, 10-26)：10-23 完成历史行 + 10-24/25 未完成行")
        let completedRows = results.filter { $0.isCompleted }
        XCTAssertEqual(completedRows.count, 1, "仅完成历史日期产出已完成行")
        XCTAssertEqual(
            CachedEvent.parseOccurrenceID(completedRows.first?.eventID ?? "")?.occurrence,
            date(2026, 10, 23, 9, 0)
        )
    }

    /// monthly 不做对齐（月末取整累积语义）：1-31 逐次 +1 月得 2-28→3-28…，
    /// 批量月差跳转会得不同序列（10-31）——本测试锁死取整累积行为不变
    func testMonthlyExpansionKeepsCumulativeRounding() throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        try insertRecurring(
            into: container.mainContext,
            eventID: "rec-monthend",
            startDate: date(2026, 1, 31, 9, 0),
            recurrenceType: .monthly
        )
        let (start, end) = dayWindow(2026, 10, 25, days: 7)
        let results = EventCacheService.shared.getEvents(from: start, to: end)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(
            CachedEvent.parseOccurrenceID(results.first?.eventID ?? "")?.occurrence,
            date(2026, 10, 28, 9, 0),
            "monthly 序列保持逐次取整累积（1-31→2-28→…→10-28），不做批量月差对齐"
        )
    }

    /// 近锚点场景对齐不破坏行为：k 较小（≥1）时回退一周期后推进，
    /// 窗口内实例与逐次推进完全一致
    func testNearAnchorAlignedEquivalence() throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        try insertRecurring(
            into: container.mainContext,
            eventID: "rec-near",
            startDate: date(2026, 10, 20, 9, 0)
        )
        let (start, end) = dayWindow(2026, 10, 24, days: 2)
        let results = EventCacheService.shared.getEvents(from: start, to: end)

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(
            Set(results.compactMap { CachedEvent.parseOccurrenceID($0.eventID)?.occurrence }),
            [date(2026, 10, 24, 9, 0), date(2026, 10, 25, 9, 0)]
        )
    }

    // MARK: - 历史锚点 originStartDate（bug: recurring-past-occurrence-invisible）

    /// 完成推进把游标（startDate）前移后，被越过的历史未完成实例应保持可见
    /// 场景：每天 09:00 任务创建于 10/25（originStart），10/28 实例完成后游标
    /// 推进到 10/29；回看 10/26 窗口，10/26 未完成实例应展开（现状无行 → RED）
    func testAdvancedCursorKeepsPastUncompletedOccurrences() throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        try insertRecurring(
            into: container.mainContext,
            eventID: "rec-anchor",
            startDate: date(2026, 10, 29, 9, 0),
            completed: [date(2026, 10, 28, 9, 0)],
            originStartDate: date(2026, 10, 25, 9, 0)
        )
        let (start, end) = dayWindow(2026, 10, 26)
        let results = EventCacheService.shared.getEvents(from: start, to: end)

        XCTAssertEqual(results.count, 1, "游标越过的历史未完成实例应保持可见")
        XCTAssertEqual(
            CachedEvent.parseOccurrenceID(results.first?.eventID ?? "")?.occurrence,
            date(2026, 10, 26, 9, 0)
        )
        XCTAssertEqual(results.first?.isCompleted, false, "历史锚点展开的是未完成实例")
    }

    /// 完成历史行与历史锚点展开不重复：窗口含已完成日 + 未完成日
    func testAnchorExpansionDoesNotDuplicateCompletedRows() throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        // 10/26 已完成并推进（游标 10/29），10/27 未完成：锚点展开应补出 10/27，
        // 10/26 仍由完成历史独家产出，且 10/28 等未来序列行正常
        try insertRecurring(
            into: container.mainContext,
            eventID: "rec-anchor2",
            startDate: date(2026, 10, 29, 9, 0),
            completed: [date(2026, 10, 26, 9, 0)],
            originStartDate: date(2026, 10, 25, 9, 0)
        )
        let (start, end) = dayWindow(2026, 10, 26, days: 3)
        let results = EventCacheService.shared.getEvents(from: start, to: end)

        // 窗口 [10/26, 10/29)：10/26 历史行（完成）+ 10/27、10/28 未完成锚点展开行
        XCTAssertEqual(results.count, 3, "历史行 + 锚点展开行不应重复或遗漏")
        let completedRows = results.filter { $0.isCompleted }
        let uncompletedRows = results.filter { !$0.isCompleted }
        XCTAssertEqual(completedRows.count, 1)
        XCTAssertEqual(
            CachedEvent.parseOccurrenceID(completedRows.first?.eventID ?? "")?.occurrence,
            date(2026, 10, 26, 9, 0)
        )
        XCTAssertEqual(Set(uncompletedRows.compactMap {
            CachedEvent.parseOccurrenceID($0.eventID)?.occurrence
        }), [date(2026, 10, 27, 9, 0), date(2026, 10, 28, 9, 0)])
    }

    /// 存量兼容：originStartDate 未回填（nil）时回退游标展开，行为零变化
    func testNilOriginFallsBackToCursorExpansion() throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        try insertRecurring(
            into: container.mainContext,
            eventID: "rec-legacy",
            startDate: date(2026, 10, 29, 9, 0),
            completed: [date(2026, 10, 28, 9, 0)]
        )
        let (pastStart, pastEnd) = dayWindow(2026, 10, 26)
        XCTAssertEqual(
            EventCacheService.shared.getEvents(from: pastStart, to: pastEnd).count,
            0,
            "存量未回填时保持现状：游标之前不展开"
        )
        let (start, end) = dayWindow(2026, 10, 29)
        XCTAssertEqual(
            EventCacheService.shared.getEvents(from: start, to: end).count,
            1,
            "游标之后的序列行照常展开"
        )
    }

    /// 历史锚点展开仍受有效期开始端过滤（validStartDate 之前不产出）
    func testAnchorExpansionStillRespectsValidityStart() throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        let event = try insertRecurring(
            into: container.mainContext,
            eventID: "rec-anchor-valid",
            startDate: date(2026, 10, 29, 9, 0),
            originStartDate: date(2026, 10, 25, 9, 0)
        )
        event.validStartDate = date(2026, 10, 27)
        try container.mainContext.save()

        let (beforeStart, beforeEnd) = dayWindow(2026, 10, 26)
        XCTAssertEqual(
            EventCacheService.shared.getEvents(from: beforeStart, to: beforeEnd).count,
            0,
            "有效期开始端之前的实例不产出"
        )
        let (start, end) = dayWindow(2026, 10, 27)
        XCTAssertEqual(
            EventCacheService.shared.getEvents(from: start, to: end).count,
            1,
            "有效期开始端当日实例正常产出"
        )
    }

    /// 防御：异常数据 originStart 晚于游标时取两者较早者，不产生额外空档
    func testOriginLaterThanCursorTakesEarliest() throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        try insertRecurring(
            into: container.mainContext,
            eventID: "rec-anchor-bad",
            startDate: date(2026, 10, 29, 9, 0),
            originStartDate: date(2026, 11, 2, 9, 0)
        )
        let (start, end) = dayWindow(2026, 10, 30)
        XCTAssertEqual(
            EventCacheService.shared.getEvents(from: start, to: end).count,
            1,
            "originStart 异常晚于游标时按游标展开"
        )
    }
}
