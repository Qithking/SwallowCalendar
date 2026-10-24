//
//  HolidaySkipResolverTests.swift
//  SwallowCalendarTests
//
//  智能跳过节假日：休日静默跳过判定测试（spec: smart-holiday-skip 语义 v3，取消顺延）
//

import XCTest
import SwiftData
@testable import SwallowCalendar

class HolidaySkipResolverTests: XCTestCase {

    // MARK: - 测试基建

    /// 仅注册 CachedEvent 的内存 SwiftData 上下文，测试互不污染
    @MainActor
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: CachedEvent.self, configurations: config)
        return ModelContext(container)
    }

    /// 构造指定年月日时刻的 Date（本地时区）
    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    /// 插入一条全天节假日标识事件（start=当日 00:00，end=次日 00:00，与 EventKit 全天事件形态一致）
    @MainActor
    private func insertAllDayMark(_ context: ModelContext, title: String, day: Date) {
        let dayStart = Calendar.current.startOfDay(for: day)
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart)!
        let event = CachedEvent(
            eventID: UUID().uuidString,
            title: title,
            startDate: dayStart,
            endDate: dayEnd,
            isAllDay: true,
            calendarID: "holiday",
            calendarTitle: "中国节假日",
            calendarColorHex: "#FF9500",
            category: .system
        )
        context.insert(event)
    }

    /// 插入一条勾选智能跳过的用户任务（默认勾选）
    @MainActor
    private func insertTask(_ context: ModelContext, id: String, start: Date?, skipHolidays: Bool = true) -> CachedEvent {
        let event = CachedEvent(
            eventID: id,
            title: "任务-\(id)",
            startDate: start,
            endDate: start,
            isAllDay: false,
            calendarID: "test-cal",
            calendarTitle: "测试日历",
            calendarColorHex: "#007AFF",
            category: .user,
            skipHolidays: skipHolidays
        )
        context.insert(event)
        return event
    }

    // MARK: - 休日静默跳过判定（语义 v3：不显示不提醒，无顺延）

    /// 休标识日任务判定为跳过，且 startDate 持久值不变（无顺延改写）
    @MainActor
    func testRestDaySkipped() throws {
        let context = try makeContext()
        insertAllDayMark(context, title: "国庆节（休）", day: date(2026, 10, 1))
        let task = insertTask(context, id: "rest-task", start: date(2026, 10, 1, 9, 30))
        try context.save()

        XCTAssertTrue(HolidaySkipResolver.isSkipped(of: task, context: context), "休日任务应判定为跳过")
        XCTAssertEqual(task.startDate, date(2026, 10, 1, 9, 30), "跳过不改写 startDate，任务保留原日期")
    }

    /// 班日（补班）视为工作日，照常不跳过
    @MainActor
    func testWorkdayMarkedDayNotSkipped() throws {
        let context = try makeContext()
        insertAllDayMark(context, title: "国庆节补班", day: date(2026, 10, 10))
        let task = insertTask(context, id: "work-task", start: date(2026, 10, 10, 14, 0))
        try context.save()

        XCTAssertFalse(HolidaySkipResolver.isSkipped(of: task, context: context), "班日（补班）应照常执行")
    }

    /// 普通工作日（无节假日标识）不跳过
    @MainActor
    func testOrdinaryDayNotSkipped() throws {
        let context = try makeContext()
        let task = insertTask(context, id: "normal-task", start: date(2026, 10, 13, 8, 0))
        try context.save()

        XCTAssertFalse(HolidaySkipResolver.isSkipped(of: task, context: context), "普通工作日应照常执行")
    }

    /// 周六/周日按休处理：跳过（确定性规则，不依赖节假日数据）
    @MainActor
    func testWeekendSkipped() throws {
        let context = try makeContext()
        let saturday = insertTask(context, id: "sat-task", start: date(2026, 10, 24, 9, 0))  // 10-24 周六
        let sunday = insertTask(context, id: "sun-task", start: date(2026, 10, 25, 15, 30))  // 10-25 周日
        try context.save()

        XCTAssertTrue(HolidaySkipResolver.isSkipped(of: saturday, context: context), "周六无标识按休跳过")
        XCTAssertTrue(HolidaySkipResolver.isSkipped(of: sunday, context: context), "周日无标识按休跳过")
    }

    /// 补班周六（有「班」标识）优先于周末规则，照常不跳过
    @MainActor
    func testWorkMarkedSaturdayNotSkipped() throws {
        let context = try makeContext()
        insertAllDayMark(context, title: "国庆节补班", day: date(2026, 10, 24))  // 周六
        let task = insertTask(context, id: "sat-work", start: date(2026, 10, 24, 9, 0))
        try context.save()

        XCTAssertFalse(HolidaySkipResolver.isSkipped(of: task, context: context), "补班周六班标识应优先于周末规则")
    }

    /// 连休期间任务全部跳过，休后首日不跳过
    @MainActor
    func testMultiDayRestChainSkipped() throws {
        let context = try makeContext()
        insertAllDayMark(context, title: "春节假期", day: date(2026, 2, 15))
        insertAllDayMark(context, title: "春节假期", day: date(2026, 2, 16))
        insertAllDayMark(context, title: "春节假期", day: date(2026, 2, 17))
        let d15 = insertTask(context, id: "d15", start: date(2026, 2, 15, 20, 0))
        let d16 = insertTask(context, id: "d16", start: date(2026, 2, 16, 20, 0))
        let d17 = insertTask(context, id: "d17", start: date(2026, 2, 17, 20, 0))
        let d18 = insertTask(context, id: "d18", start: date(2026, 2, 18, 20, 0))
        try context.save()

        XCTAssertTrue(HolidaySkipResolver.isSkipped(of: d15, context: context))
        XCTAssertTrue(HolidaySkipResolver.isSkipped(of: d16, context: context))
        XCTAssertTrue(HolidaySkipResolver.isSkipped(of: d17, context: context))
        XCTAssertFalse(HolidaySkipResolver.isSkipped(of: d18, context: context), "休后首日应照常执行")
    }

    /// 休标识落周五：周五与随后的周末（周末规则）都跳过，下周一不跳过
    @MainActor
    func testFridayRestOverWeekend() throws {
        let context = try makeContext()
        insertAllDayMark(context, title: "调休（休）", day: date(2026, 10, 23))  // 周五
        let fri = insertTask(context, id: "fri", start: date(2026, 10, 23, 10, 0))
        let mon = insertTask(context, id: "mon", start: date(2026, 10, 26, 10, 0))
        try context.save()

        XCTAssertTrue(HolidaySkipResolver.isSkipped(of: fri, context: context), "周五休跳过")
        XCTAssertFalse(HolidaySkipResolver.isSkipped(of: mon, context: context), "下周一照常执行")
    }

    /// fail-open：context 缺失或缓存无数据时——周末规则仍生效（确定性），平日照常
    @MainActor
    func testFailOpenWeekendSkippedWeekdayNot() throws {
        let saturday = date(2026, 10, 24, 9, 0)
        let tuesday = date(2026, 10, 27, 9, 0)
        XCTAssertTrue(
            HolidaySkipResolver.isRestDay(saturday, context: nil),
            "context 缺失时周六仍按周末规则判定为休日"
        )
        XCTAssertFalse(
            HolidaySkipResolver.isRestDay(tuesday, context: nil),
            "context 缺失时平日 fail-open 按工作日"
        )

        let emptyContext = try makeContext()
        XCTAssertTrue(
            HolidaySkipResolver.isRestDay(saturday, context: emptyContext),
            "缓存无数据时周六仍按周末规则判定为休日"
        )
        XCTAssertFalse(
            HolidaySkipResolver.isRestDay(tuesday, context: emptyContext),
            "缓存无数据时平日按工作日"
        )
    }

    /// 跨月与跨年休日跳过判定（周末规则叠加）
    @MainActor
    func testCrossMonthAndCrossYearSkipped() throws {
        let context = try makeContext()
        // 跨月：10-31（周六）有休标识 → 跳过；11-2（周一）休后首日 → 照常
        insertAllDayMark(context, title: "月末（休）", day: date(2026, 10, 31))
        let oct31 = insertTask(context, id: "oct31", start: date(2026, 10, 31, 7, 0))
        let nov2 = insertTask(context, id: "nov2", start: date(2026, 11, 2, 7, 0))
        // 跨年：12-31 与次年 1-1 连休 → 跳过；1-4（周一）照常
        insertAllDayMark(context, title: "元旦（休）", day: date(2026, 12, 31))
        insertAllDayMark(context, title: "元旦（休）", day: date(2027, 1, 1))
        let dec31 = insertTask(context, id: "dec31", start: date(2026, 12, 31, 23, 0))
        let jan4 = insertTask(context, id: "jan4", start: date(2027, 1, 4, 23, 0))
        try context.save()

        XCTAssertTrue(HolidaySkipResolver.isSkipped(of: oct31, context: context), "10-31 休标识+周六应跳过")
        XCTAssertFalse(HolidaySkipResolver.isSkipped(of: nov2, context: context), "11-2 休后首日照常")
        XCTAssertTrue(HolidaySkipResolver.isSkipped(of: dec31, context: context), "12-31 休标识应跳过")
        XCTAssertFalse(HolidaySkipResolver.isSkipped(of: jan4, context: context), "1-4（周一）照常")
    }

    /// 未勾选任务即使落休日也照常（零变化）
    @MainActor
    func testUncheckedTaskNeverSkipped() throws {
        let context = try makeContext()
        insertAllDayMark(context, title: "国庆节（休）", day: date(2026, 10, 1))
        let task = insertTask(context, id: "unchecked", start: date(2026, 10, 1, 9, 30), skipHolidays: false)
        try context.save()

        XCTAssertFalse(HolidaySkipResolver.isSkipped(of: task, context: context), "未勾选任务不参与智能跳过")
    }

    /// 无日期任务不跳过（无日期无跳过语义）
    @MainActor
    func testNilStartDateNeverSkipped() throws {
        let context = try makeContext()
        let task = insertTask(context, id: "nodate", start: nil)
        try context.save()

        XCTAssertFalse(HolidaySkipResolver.isSkipped(of: task, context: context), "无日期任务无跳过语义")
    }

    // MARK: - V-35 关键词匹配器（单一真源口径锁定）

    /// V-35 口径锁定：休/班关键词集合（全/半角括号），防关键词漂移
    func testTitleKeywordSetsMatchV35Scope() {
        XCTAssertEqual(HolidaySkipResolver.restTitleKeywords, ["假期", "（休）", "(休)"], "休关键词口径变化须同步 V-35 设计")
        XCTAssertEqual(HolidaySkipResolver.workTitleKeywords, ["补班", "（班）", "(班)"], "班关键词口径变化须同步 V-35 设计")
    }

    /// 休匹配：命中「假期」与全/半角（休），不命中班标题与普通标题
    func testIsRestTitleKeywordMatching() {
        XCTAssertTrue(HolidaySkipResolver.isRestTitle("国庆节假期"))
        XCTAssertTrue(HolidaySkipResolver.isRestTitle("国庆节（休）"))
        XCTAssertTrue(HolidaySkipResolver.isRestTitle("国庆节(休)"))
        XCTAssertFalse(HolidaySkipResolver.isRestTitle("国庆节补班"), "班标题不得命中休匹配")
        XCTAssertFalse(HolidaySkipResolver.isRestTitle("团队周会"))
    }

    /// 班匹配：命中「补班」与全/半角（班），不命中休标题与普通标题
    func testIsWorkTitleKeywordMatching() {
        XCTAssertTrue(HolidaySkipResolver.isWorkTitle("国庆节补班"))
        XCTAssertTrue(HolidaySkipResolver.isWorkTitle("国庆节（班）"))
        XCTAssertTrue(HolidaySkipResolver.isWorkTitle("国庆节(班)"))
        XCTAssertFalse(HolidaySkipResolver.isWorkTitle("国庆节（休）"), "休标题不得命中班匹配")
        XCTAssertFalse(HolidaySkipResolver.isWorkTitle("团队周会"))
    }
}
