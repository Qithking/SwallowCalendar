//  MonthPickerCellRoleTests.swift
//  SwallowCalendarTests
//
//  年月选择弹框月格角色判定测试
//  （只有今天所在月用主题色淡化背景标识，浏览月不做背景标记）
//

import XCTest
@testable import SwallowCalendar

final class MonthPickerCellRoleTests: XCTestCase {

    private let calendar = Calendar.current

    /// 已知事实：2026-11-11 为今天（周三）
    private func november11(_ y: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: 11, day: 11, hour: 12))!
    }

    // MARK: - 今天所在月判定

    /// 今天所在年月判为今天月（2026 年 11 月）
    func testIsTodayMonthMatchesYearAndMonth() {
        let now = november11(2026)
        XCTAssertTrue(MonthPickerCellRole.isTodayMonth(year: 2026, month: 11, now: now, calendar: calendar))
    }

    /// 同年不同月、不同年同月均不判为今天月
    func testIsTodayMonthRejectsDifferentYearOrMonth() {
        let now = november11(2026)
        XCTAssertFalse(MonthPickerCellRole.isTodayMonth(year: 2026, month: 10, now: now, calendar: calendar))
        XCTAssertFalse(MonthPickerCellRole.isTodayMonth(year: 2025, month: 11, now: now, calendar: calendar))
        XCTAssertFalse(MonthPickerCellRole.isTodayMonth(year: 2027, month: 11, now: now, calendar: calendar))
    }

    // MARK: - 月格角色

    /// 今天所在月 → 主题色淡化背景
    func testTodayMonthRole() {
        XCTAssertEqual(
            MonthPickerCellRole.cellRole(isTodayMonth: true),
            .todayMonth
        )
    }

    /// 非今天月（含正在浏览的月份）→ 无背景标识
    func testNormalMonthRole() {
        XCTAssertEqual(
            MonthPickerCellRole.cellRole(isTodayMonth: false),
            .normal
        )
    }
}
