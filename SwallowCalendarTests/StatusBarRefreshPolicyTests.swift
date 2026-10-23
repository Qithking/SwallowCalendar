//
//  StatusBarRefreshPolicyTests.swift
//  SwallowCalendarTests
//
//  badge-realtime-countdown B3 回归测试：菜单栏图标刷新间隔策略
//  徽标开启 → 固定 1s 实时节奏；徽标关闭 → 按图标样式精度分档
//

import XCTest
@testable import SwallowCalendar

final class StatusBarRefreshPolicyTests: XCTestCase {

    // MARK: - 徽标开启：固定 1s（覆盖所有图标样式）

    func testBadgeEnabledReturnsOneSecond() {
        XCTAssertEqual(StatusBarRefreshPolicy.computeRefreshInterval(iconStyle: .solidDate, customFormat: "", badgeEnabled: true), 1)
        XCTAssertEqual(StatusBarRefreshPolicy.computeRefreshInterval(iconStyle: .strokeDate, customFormat: "", badgeEnabled: true), 1)
        XCTAssertEqual(StatusBarRefreshPolicy.computeRefreshInterval(iconStyle: .calendarIcon, customFormat: "", badgeEnabled: true), 1)
        XCTAssertEqual(StatusBarRefreshPolicy.computeRefreshInterval(iconStyle: .customFormat, customFormat: "HH:mm:ss", badgeEnabled: true), 1)
        XCTAssertEqual(StatusBarRefreshPolicy.computeRefreshInterval(iconStyle: .customFormat, customFormat: "MM月dd日", badgeEnabled: true), 1)
    }

    // MARK: - 徽标关闭：保持按样式精度分档

    func testBadgeDisabledUsesStyleBase() {
        XCTAssertEqual(StatusBarRefreshPolicy.computeRefreshInterval(iconStyle: .solidDate, customFormat: "", badgeEnabled: false), 60)
        XCTAssertEqual(StatusBarRefreshPolicy.computeRefreshInterval(iconStyle: .strokeDate, customFormat: "", badgeEnabled: false), 60)
        XCTAssertEqual(StatusBarRefreshPolicy.computeRefreshInterval(iconStyle: .calendarIcon, customFormat: "", badgeEnabled: false), 0)
        XCTAssertEqual(StatusBarRefreshPolicy.computeRefreshInterval(iconStyle: .customFormat, customFormat: "HH:mm:ss", badgeEnabled: false), 1)
        XCTAssertEqual(StatusBarRefreshPolicy.computeRefreshInterval(iconStyle: .customFormat, customFormat: "MM月dd日", badgeEnabled: false), 60)
    }
}
