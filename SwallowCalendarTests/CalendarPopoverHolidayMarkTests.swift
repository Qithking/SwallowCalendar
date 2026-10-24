//  CalendarPopoverHolidayMarkTests.swift
//  SwallowCalendarTests
//
//  智能跳过节假日：日期格 hover 弹窗行标识判定测试
//  （语义 v3 静默跳过：原休日格行显示「已智能跳过」，无顺延概念）
//

import XCTest
@testable import SwallowCalendar

final class CalendarPopoverHolidayMarkTests: XCTestCase {

    private let calendar = Calendar.current

    // 固定日期：原日期 10-01（休日），任务 10:00
    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    // MARK: - mark 判定（弹窗行标识）

    /// 未勾选跳过：无任何标识
    func testNoSkipFlagReturnsNone() {
        let start = date(2026, 10, 1)
        let mark = CalendarPopoverHolidayMark.mark(
            skipHolidays: false,
            isSkippedDay: true,
            startDate: start,
            on: start,
            calendar: calendar
        )
        XCTAssertEqual(mark, .none)
    }

    /// 勾选但 startDate 非休日（班日照常 / 数据缺失 fail-open）：无标识
    func testNotSkippedDayReturnsNone() {
        let start = date(2026, 10, 1)
        let mark = CalendarPopoverHolidayMark.mark(
            skipHolidays: true,
            isSkippedDay: false,
            startDate: start,
            on: start,
            calendar: calendar
        )
        XCTAssertEqual(mark, .none)
    }

    /// 勾选且已跳过：原休日格子行显示「已智能跳过」
    func testOriginalDayMarkedSkipped() {
        let start = date(2026, 10, 1)
        let mark = CalendarPopoverHolidayMark.mark(
            skipHolidays: true,
            isSkippedDay: true,
            startDate: start,
            on: start,
            calendar: calendar
        )
        XCTAssertEqual(mark, .skipped)
    }

    /// 勾选且已跳过：其他日期格子无标识（任务只显示在原日期，无顺延日）
    func testOtherDayMarkedNone() {
        let mark = CalendarPopoverHolidayMark.mark(
            skipHolidays: true,
            isSkippedDay: true,
            startDate: date(2026, 10, 1),
            on: date(2026, 10, 5),
            calendar: calendar
        )
        XCTAssertEqual(mark, .none)
    }

    /// startDate 缺失（异常数据）：无标识
    func testNilStartDateReturnsNone() {
        let mark = CalendarPopoverHolidayMark.mark(
            skipHolidays: true,
            isSkippedDay: true,
            startDate: nil,
            on: date(2026, 10, 1),
            calendar: calendar
        )
        XCTAssertEqual(mark, .none)
    }
}
