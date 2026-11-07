//
//  HolidaySkipCacheTests.swift
//  SwallowCalendarTests
//
//  bug: holiday-skip-n-plus-one / startup-expired-check-n-plus-one
//  休日判定日粒度缓存 + 展开批量预热：判定语义必须与逐日 isRestDay 完全一致
//  （① 班标识优先 → 工作日；② 休标识 → 休日；③ 无标识日周末规则）
//

import XCTest
import SwiftData
@testable import SwallowCalendar

@MainActor
final class HolidaySkipCacheTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        // 判定缓存按 context 身份分桶（跨用例天然隔离），仍显式清空防通知残留
        HolidaySkipResolver.invalidateDayVerdictCache()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: CachedEvent.self, configurations: config)
        context = ModelContext(container)
    }

    override func tearDownWithError() throws {
        HolidaySkipResolver.invalidateDayVerdictCache()
        container = nil
        context = nil
    }

    /// 固定日期：2026-11-02 为周一，11-03 周二 …… 11-08 周日
    private func day(_ d: Int, hour: Int = 9) -> Date {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 11
        comps.day = d
        comps.hour = hour
        return Calendar.current.date(from: comps)!
    }

    private func insertEvent(id: String, title: String, start: Date, end: Date) throws {
        let event = CachedEvent(
            eventID: id,
            title: title,
            startDate: start,
            endDate: end,
            isAllDay: false,
            calendarID: "test",
            calendarTitle: "测试",
            calendarColorHex: "#FF9500"
        )
        context.insert(event)
        try context.save()
    }

    // V-1: 预热后判定走缓存（删除数据源不广播仍返回原判定），显式失效后回归查库
    func testWarmMakesRestDayVerdictCachedAndInvalidatable() throws {
        // 周三 11-04 零长休标识事件
        try insertEvent(id: "hol-1", title: "中秋假期日", start: day(4), end: day(4))
        HolidaySkipResolver.warmRestFlags(from: day(2), to: day(6), context: context)
        XCTAssertTrue(HolidaySkipResolver.isRestDay(day(4), context: context), "周三命中休标识 → 休日")

        // 删除数据源且不广播变更通知：缓存仍命中 → 证明判定来自缓存而非查库
        let all = try context.fetch(FetchDescriptor<CachedEvent>())
        context.delete(all[0])
        try context.save()
        XCTAssertTrue(HolidaySkipResolver.isRestDay(day(4), context: context), "预热缓存应命中，不受数据源删除影响")

        // 显式失效后重新查库 → 休标识已删 → 周三工作日
        HolidaySkipResolver.invalidateDayVerdictCache()
        XCTAssertFalse(HolidaySkipResolver.isRestDay(day(4), context: context), "失效后应重新查库")
    }

    // V-2: 多日休事件逐日覆盖 + 班标识优先于周末 + 无标识日周末兜底
    func testWarmMultiDayCoverageWithWorkOverrideAndWeekend() throws {
        // 周一 00:00 → 周六 00:00：覆盖周一~周五
        try insertEvent(id: "hol-rest", title: "春节假期", start: day(2, hour: 0), end: day(7, hour: 0))
        // 周六补班 → 班优先于周末
        try insertEvent(id: "hol-work", title: "周六补班", start: day(7, hour: 0), end: day(7, hour: 1))
        HolidaySkipResolver.warmRestFlags(from: day(2), to: day(9), context: context)

        XCTAssertTrue(HolidaySkipResolver.isRestDay(day(2), context: context), "周一覆盖休标识 → 休日")
        XCTAssertTrue(HolidaySkipResolver.isRestDay(day(6), context: context), "周五覆盖休标识 → 休日")
        XCTAssertFalse(HolidaySkipResolver.isRestDay(day(7), context: context), "周六补班 → 班优先，工作日")
        XCTAssertTrue(HolidaySkipResolver.isRestDay(day(8), context: context), "周日无标识 → 周末规则休日")
    }

    // V-3（A-2 集成回归）：启动过期检查预热后，循环展开休日实例仍按逐日语义跳过
    func testExpiredCheckCandidatesSkipsHolidayOccurrenceAfterWarm() throws {
        // 每日 09:00-10:00 循环任务：锚点 11-02 周一，游标 11-10（未完成历史 11-02~11-09）
        let base = CachedEvent(
            eventID: "re-daily",
            title: "每日任务",
            startDate: day(10),
            endDate: day(10, hour: 10),
            isAllDay: false,
            calendarID: "test",
            calendarTitle: "测试",
            calendarColorHex: "#FF9500",
            category: .user,
            recurrenceType: .daily,
            skipHolidays: true,
            originStartDate: day(2)
        )
        context.insert(base)
        // 周四 11-05 零长休标识
        try insertEvent(id: "hol-1", title: "中秋假期日", start: day(5), end: day(5))

        let candidates = try ReminderAlertService.expiredCheckCandidates(
            rawEvents: [],
            upperBound: day(9, hour: 12),
            context: context
        )
        // 期望：11-02/03/04/06/09 五天（11-05 休跳过、11-07/08 周末跳过）
        let days = Set(candidates.compactMap { event in
            event.startDate.map { Calendar.current.component(.day, from: $0) }
        })
        XCTAssertEqual(days, [2, 3, 4, 6, 9], "休日与周末 occurrence 跳过，其余保留")
    }
}
