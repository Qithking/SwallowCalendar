//
//  RecurrenceExpansionTests.swift
//  SwallowCalendarTests
//
//  循环任务单条化 Behavior 2：nextOccurrence 确定性单步推进
//  （与当前时间无关，供虚拟展开与完成推进共用；monthly 走 B-16 锚定日语义）
//  Source: plan/recurring-task-single-record.md step 3

import XCTest
import SwiftData
@testable import SwallowCalendar

final class RecurrenceExpansionTests: XCTestCase {

    /// 用本地时区构造测试日期（实现使用 Calendar.current，测试保持同一口径）
    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 9) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        return Calendar.current.date(from: comps)!
    }

    func testDailyAdvancesExactlyOneDayRegardlessOfNow() {
        let base = date(2030, 5, 10)
        // base 在未来（晚于测试执行时刻），仍必须精确 +1 天——确定性推进与 now 无关
        let next = CalendarService.nextOccurrence(after: base, recurrenceType: .daily, isLunar: false)
        XCTAssertEqual(next, date(2030, 5, 11))
    }

    func testWeeklyAdvancesOneWeek() {
        let next = CalendarService.nextOccurrence(after: date(2030, 5, 10), recurrenceType: .weekly, isLunar: false)
        XCTAssertEqual(next, date(2030, 5, 17))
    }

    func testMonthlyAnchorsToMonthEnd() {
        // 口径变更（对齐提醒事项）：锚定 31 日遇小月无此日期 → 该月跳过，不回弹
        let origin = date(2026, 1, 31)
        let next = CalendarService.nextOccurrence(
            after: origin, recurrenceType: .monthly, isLunar: false, origin: origin)
        XCTAssertEqual(next, date(2026, 3, 31))
        let afterMar = CalendarService.nextOccurrence(
            after: next!, recurrenceType: .monthly, isLunar: false, origin: origin)
        XCTAssertEqual(afterMar, date(2026, 5, 31))
    }

    func testMonthlyWithoutOriginSkipsMissingMonths() {
        // 未传锚点时以游标日为锚：1/31 → 3/31 → 5/31（缺失日期一律跳过）
        let next = CalendarService.nextOccurrence(after: date(2026, 1, 31), recurrenceType: .monthly, isLunar: false)
        XCTAssertEqual(next, date(2026, 3, 31))
        let afterMar = CalendarService.nextOccurrence(after: next!, recurrenceType: .monthly, isLunar: false)
        XCTAssertEqual(afterMar, date(2026, 5, 31))
    }

    func testYearlyLeapDayAnchorsBackToLeapYear() {
        // 口径变更：2/29 在非闰年无此日期 → 跳过，直到下一个闰年
        let origin = date(2028, 2, 29)
        XCTAssertEqual(
            CalendarService.nextOccurrence(after: origin, recurrenceType: .yearly, isLunar: false, origin: origin),
            date(2032, 2, 29))
        XCTAssertEqual(
            CalendarService.nextOccurrence(after: date(2031, 2, 28), recurrenceType: .yearly, isLunar: false, origin: origin),
            date(2032, 2, 29))
    }

    func testAnchoredPreviousOccurrenceIsSymmetric() {
        let origin = date(2026, 1, 31)
        XCTAssertEqual(
            CalendarService.previousOccurrence(before: date(2026, 2, 28), recurrenceType: .monthly, isLunar: false, origin: origin),
            origin)
        XCTAssertNil(
            CalendarService.previousOccurrence(before: origin, recurrenceType: .monthly, isLunar: false, origin: origin),
            "origin 之前无 occurrence")
    }

    func testMigrationRekeysDriftedCompletionDates() {
        // 口径变更：2/28 在锚定 31 日的序列中已不存在 → 迁移时丢弃；3/28 重定键为 3/31
        let origin = date(2026, 1, 31)
        let migrated = CachedEvent.migratedAnchorCompletionDates(
            [date(2026, 1, 31), date(2026, 2, 28), date(2026, 3, 28)],
            origin: origin,
            recurrenceType: .monthly
        )
        XCTAssertEqual(migrated, [date(2026, 1, 31), date(2026, 3, 31)])
    }

    func testYearlyAdvancesOneYear() {
        let next = CalendarService.nextOccurrence(after: date(2026, 10, 24), recurrenceType: .yearly, isLunar: false)
        XCTAssertEqual(next, date(2027, 10, 24))
    }

    func testLunarMonthlyAdvancesOneLunarMonth() {
        // 农历走 Calendar(identifier: .chinese) 推进（B-17 系统取整语义）
        let base = date(2026, 10, 24)
        let next = CalendarService.nextOccurrence(after: base, recurrenceType: .monthly, isLunar: true)
        XCTAssertNotNil(next)
        // 农历一个月 ≈ 29/30 天，公历跨度必须落在 [28, 32] 天区间
        let gap = next!.timeIntervalSince(base) / 86_400
        XCTAssertTrue((28..<32).contains(gap), "农历月跨度异常: \(gap) 天")
    }

    func testNoneAndCustomReturnNil() {
        XCTAssertNil(CalendarService.nextOccurrence(after: date(2026, 10, 24), recurrenceType: .none, isLunar: false))
        XCTAssertNil(CalendarService.nextOccurrence(after: date(2026, 10, 24), recurrenceType: .custom, isLunar: false))
    }

    /// BUG-19：过去时刻创建的每小时任务必须推进到未来（否则立即逾期、系统侧落在过去）
    func testHourlyAdvanceRecurrenceDateMovesIntoFuture() {
        let base = Calendar.current.date(byAdding: .hour, value: -3, to: Date())!
        let advanced = CalendarService.advanceRecurrenceDate(base, recurrenceType: .hourly)

        XCTAssertGreaterThan(advanced, Date(), "每小时循环必须推进到当前时间之后")
        // 按整小时步进：分钟/秒与基准保持一致
        let baseComps = Calendar.current.dateComponents([.minute, .second], from: base)
        let advComps = Calendar.current.dateComponents([.minute, .second], from: advanced)
        XCTAssertEqual(advComps.minute, baseComps.minute)
        XCTAssertEqual(advComps.second, baseComps.second)
    }

    /// 对照：.custom 无推进语义，过去日期保持原值（护栏不得误伤）
    func testCustomAdvanceRecurrenceDateKeepsPastDate() {
        let base = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let advanced = CalendarService.advanceRecurrenceDate(base, recurrenceType: .custom)
        XCTAssertEqual(advanced.timeIntervalSince1970, base.timeIntervalSince1970, accuracy: 0.001)
    }

    /// 重叠循环跨窗口兜底（对齐后回退一个周期）：实例时长 > 周期 + 相位差时，
    /// 窗口前缘落在某实例中间，比 aligned 更早一期的跨窗口实例
    /// （occ < windowStart 但 instanceEnd > windowStart）也必须产出，
    /// 否则窗口顶部少显示一行
    @MainActor
    func testExpansionStepsBackOnePeriodForOverlappingLongInstances() throws {
        let container = try ModelContainer(
            for: CachedEvent.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        EventCacheService.shared.configure(with: container)
        let origin = date(2030, 5, 10, 9)  // 锚点 09:00
        let event = CachedEvent(
            eventID: "overlap-hourly",
            title: "每小时长任务",
            startDate: origin,
            endDate: origin.addingTimeInterval(2 * 3600),  // 实例 2h > 周期 1h
            isAllDay: false,
            calendarID: "reminder",
            calendarTitle: "提醒",
            calendarColorHex: "#FF0000",
            recurrenceType: .hourly
        )
        event.originStartDate = origin

        // When: 窗口前缘 10:30 落在 10:00 实例（10:00-12:00）中间——
        // 9:00 实例（9:00-11:00）同样跨窗口，必须随「回退一个周期」兜底产出
        let windowStart = date(2030, 5, 10, 10).addingTimeInterval(30 * 60)
        let windowEnd = date(2030, 5, 10, 12).addingTimeInterval(30 * 60)
        let instances = EventCacheService.shared.expandOccurrences(
            of: event, windowStart: windowStart, windowEnd: windowEnd,
            context: container.mainContext
        )

        // Then: 9/10/11/12 时四行（当前缺 9:00 兜底行）
        let starts = instances.compactMap(\.startDate).map { $0.timeIntervalSince1970 }
        XCTAssertTrue(
            starts.contains(origin.timeIntervalSince1970),
            "9:00 跨窗口实例必须产出（对齐回退一个周期兜底），实际起点: \(starts)"
        )
        XCTAssertEqual(instances.count, 4, "应产出 9/10/11/12 时四行，实际 \(instances.count) 行")
    }
}
