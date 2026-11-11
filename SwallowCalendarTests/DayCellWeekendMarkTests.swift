//  DayCellWeekendMarkTests.swift
//  SwallowCalendarTests
//
//  周末标记设置：日期格文字颜色角色判定测试
//  （设置开启后，当月周六/周日日期文字使用主题色；
//    今天 > 选中 > 非当月淡化 优先级保持不变）
//

import XCTest
@testable import SwallowCalendar

final class DayCellWeekendMarkTests: XCTestCase {

    private let calendar = Calendar.current

    /// 固定日期构造（已知事实：2026-11-14 为周六、11-15 为周日、11-11 为周三）
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    // MARK: - 周末判定

    /// 周六、周日判为周末
    func testIsWeekendDetectsSaturdayAndSunday() {
        XCTAssertTrue(DayCellTextRole.isWeekend(date(2026, 11, 14), calendar: calendar))
        XCTAssertTrue(DayCellTextRole.isWeekend(date(2026, 11, 15), calendar: calendar))
    }

    /// 平日（周三）不判为周末
    func testWeekdayIsNotWeekend() {
        XCTAssertFalse(DayCellTextRole.isWeekend(date(2026, 11, 11), calendar: calendar))
    }

    /// 周末判定与「星期起始日」设置无关（weekday 为绝对值：1=周日…7=周六）
    func testIsWeekendIndependentOfFirstWeekday() {
        var mondayFirst = calendar
        mondayFirst.firstWeekday = 2  // 周一起始
        XCTAssertTrue(DayCellTextRole.isWeekend(date(2026, 11, 14), calendar: mondayFirst))

        var sundayFirst = calendar
        sundayFirst.firstWeekday = 1  // 周日起始
        XCTAssertTrue(DayCellTextRole.isWeekend(date(2026, 11, 14), calendar: sundayFirst))
    }

    // MARK: - 文字颜色角色（优先级矩阵）

    /// 开启设置：当月普通周末 → 周末主题色
    func testEnabledCurrentMonthWeekendIsWeekendRole() {
        XCTAssertEqual(
            DayCellTextRole.textColorRole(
                isToday: false, isSelected: false, isCurrentMonth: true,
                isWeekend: true, weekendMarkEnabled: true
            ),
            .weekend
        )
    }

    /// 开启设置：当月平日 → 普通色（不标主题色）
    func testEnabledCurrentMonthWeekdayIsNormalRole() {
        XCTAssertEqual(
            DayCellTextRole.textColorRole(
                isToday: false, isSelected: false, isCurrentMonth: true,
                isWeekend: false, weekendMarkEnabled: true
            ),
            .normal
        )
    }

    /// 关闭设置：当月周末 → 普通色（与旧行为一致，零回归）
    func testDisabledCurrentMonthWeekendIsNormalRole() {
        XCTAssertEqual(
            DayCellTextRole.textColorRole(
                isToday: false, isSelected: false, isCurrentMonth: true,
                isWeekend: true, weekendMarkEnabled: false
            ),
            .normal
        )
    }

    /// 开启设置：今天是周末 → 仍为今天白字（今天优先级最高）
    func testEnabledTodayWeekendIsTodayRole() {
        XCTAssertEqual(
            DayCellTextRole.textColorRole(
                isToday: true, isSelected: false, isCurrentMonth: true,
                isWeekend: true, weekendMarkEnabled: true
            ),
            .today
        )
    }

    /// 开启设置：选中了周末 → 仍为选中主题色（选中优先于周末）
    func testEnabledSelectedWeekendIsSelectedRole() {
        XCTAssertEqual(
            DayCellTextRole.textColorRole(
                isToday: false, isSelected: true, isCurrentMonth: true,
                isWeekend: true, weekendMarkEnabled: true
            ),
            .selected
        )
    }

    /// 开启设置：非当月的周末 → 主题色淡化（需求变更：非当月周末也标主题色，淡化处理）
    func testEnabledOutOfMonthWeekendIsDimmedAccentRole() {
        XCTAssertEqual(
            DayCellTextRole.textColorRole(
                isToday: false, isSelected: false, isCurrentMonth: false,
                isWeekend: true, weekendMarkEnabled: true
            ),
            .weekendDimmed
        )
    }

    /// 关闭设置：非当月的周末 → 普通淡化（与旧行为一致，零回归）
    func testDisabledOutOfMonthWeekendIsDimmedRole() {
        XCTAssertEqual(
            DayCellTextRole.textColorRole(
                isToday: false, isSelected: false, isCurrentMonth: false,
                isWeekend: true, weekendMarkEnabled: false
            ),
            .dimmed
        )
    }

    /// 关闭设置：今天/选中/非当月原有角色完全不变
    func testDisabledKeepsLegacyRoles() {
        XCTAssertEqual(
            DayCellTextRole.textColorRole(
                isToday: true, isSelected: false, isCurrentMonth: true,
                isWeekend: false, weekendMarkEnabled: false
            ),
            .today
        )
        XCTAssertEqual(
            DayCellTextRole.textColorRole(
                isToday: false, isSelected: true, isCurrentMonth: true,
                isWeekend: false, weekendMarkEnabled: false
            ),
            .selected
        )
        XCTAssertEqual(
            DayCellTextRole.textColorRole(
                isToday: false, isSelected: false, isCurrentMonth: false,
                isWeekend: false, weekendMarkEnabled: false
            ),
            .dimmed
        )
    }
}
