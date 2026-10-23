//
//  IconStyleBadgeStyleTests.swift
//  SwallowCalendarTests
//
//  D2b 回归测试：倒计时徽标外观与「菜单栏图标」样式逐项配合
//  （修复徽标仅跟随「自定义图标样式」导致主样式设置不生效的 bug）

import XCTest
@testable import SwallowCalendar

final class IconStyleBadgeStyleTests: XCTestCase {

    func testSolidDateMapsToSolid() {
        XCTAssertEqual(IconStyle.solidDate.badgeStyle(customFormatStyle: .none), .solid)
    }

    func testStrokeDateMapsToStroke() {
        XCTAssertEqual(IconStyle.strokeDate.badgeStyle(customFormatStyle: .none), .stroke)
    }

    func testCalendarIconMapsToNone() {
        // 日历图标对应徽标无背景纯文字（即使子选项为 solid 也不受影响）
        XCTAssertEqual(IconStyle.calendarIcon.badgeStyle(customFormatStyle: .solid), .none)
    }

    func testCustomFormatPassesThrough() {
        XCTAssertEqual(IconStyle.customFormat.badgeStyle(customFormatStyle: .none), .none)
        XCTAssertEqual(IconStyle.customFormat.badgeStyle(customFormatStyle: .solid), .solid)
        XCTAssertEqual(IconStyle.customFormat.badgeStyle(customFormatStyle: .stroke), .stroke)
    }
}
