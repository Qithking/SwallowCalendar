//
//  RecurrenceExpansionTests.swift
//  SwallowCalendarTests
//
//  循环任务单条化 Behavior 2：nextOccurrence 确定性单步推进
//  （与当前时间无关，供虚拟展开与完成推进共用；monthly 走 B-16 锚定日语义）
//  Source: plan/recurring-task-single-record.md step 3

import XCTest
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
        // spec Edge cases 定案：月末由 Calendar.date(byAdding:) 系统取整（getNextGregorianDate 语义）
        let next = CalendarService.nextOccurrence(after: date(2026, 1, 31), recurrenceType: .monthly, isLunar: false)
        XCTAssertEqual(next, date(2026, 2, 28))
        // 展开链与完成推进链共用本函数：后续从取整结果继续单步，保持自洽
        let afterFeb = CalendarService.nextOccurrence(after: next!, recurrenceType: .monthly, isLunar: false)
        XCTAssertEqual(afterFeb, date(2026, 3, 28))
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
}
