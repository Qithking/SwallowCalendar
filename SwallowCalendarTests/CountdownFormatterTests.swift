//
//  CountdownFormatterTests.swift
//  SwallowCalendarTests
//
//  倒计时格式化与临期档位测试（文案与原 CountdownTextView.updateCountdown 逐字符一致）

import XCTest
@testable import SwallowCalendar

final class CountdownFormatterTests: XCTestCase {

    // MARK: - 文案逐字符回归（AC-3）

    func testExpired() {
        XCTAssertEqual(CountdownFormatter.formatCountdown(remaining: -10), "已过期")
        XCTAssertEqual(CountdownFormatter.formatCountdown(remaining: 0), "已过期")
    }

    func testSeconds() {
        XCTAssertEqual(CountdownFormatter.formatCountdown(remaining: 59), "59秒")
        XCTAssertEqual(CountdownFormatter.formatCountdown(remaining: 59.9), "59秒")
    }

    func testMinutes() {
        XCTAssertEqual(CountdownFormatter.formatCountdown(remaining: 60), "1分0秒")
        XCTAssertEqual(CountdownFormatter.formatCountdown(remaining: 61), "1分1秒")
        XCTAssertEqual(CountdownFormatter.formatCountdown(remaining: 3599), "59分59秒")
    }

    func testHours() {
        XCTAssertEqual(CountdownFormatter.formatCountdown(remaining: 3600), "1小时")
        XCTAssertEqual(CountdownFormatter.formatCountdown(remaining: 3660), "1小时")
        XCTAssertEqual(CountdownFormatter.formatCountdown(remaining: 86399), "23小时")
    }

    func testDays() {
        XCTAssertEqual(CountdownFormatter.formatCountdown(remaining: 86400), "1天")
        XCTAssertEqual(CountdownFormatter.formatCountdown(remaining: 86400 * 2 + 3600), "2天")
    }

    func testYears() {
        XCTAssertEqual(CountdownFormatter.formatCountdown(remaining: 86400 * 365), "1年")
        XCTAssertEqual(CountdownFormatter.formatCountdown(remaining: 86400 * 366), "1年1天")
        XCTAssertEqual(CountdownFormatter.formatCountdown(remaining: 86400 * 365 * 2 + 86400 * 5), "2年5天")
    }

    // MARK: - 临期档位（AC-1：urgent <1h / approaching 1-24h / normal 其余）

    func testTierExpiredIsNormal() {
        // 已过期保持现状主题色，不参与临期色阶
        XCTAssertEqual(CountdownFormatter.tier(remaining: -10), .normal)
        XCTAssertEqual(CountdownFormatter.tier(remaining: 0), .normal)
    }

    func testTierUrgent() {
        XCTAssertEqual(CountdownFormatter.tier(remaining: 1), .urgent)
        XCTAssertEqual(CountdownFormatter.tier(remaining: 3599), .urgent)
    }

    func testTierApproaching() {
        XCTAssertEqual(CountdownFormatter.tier(remaining: 3600), .approaching)
        XCTAssertEqual(CountdownFormatter.tier(remaining: 86399), .approaching)
    }

    func testTierNormal() {
        XCTAssertEqual(CountdownFormatter.tier(remaining: 86400), .normal)
        XCTAssertEqual(CountdownFormatter.tier(remaining: 86400 * 365), .normal)
    }
}
