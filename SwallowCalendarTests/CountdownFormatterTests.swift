//
//  CountdownFormatterTests.swift
//  SwallowCalendarTests
//
//  倒计时格式化与临期档位测试（badge-realtime-countdown：实时倒计时格式）
//  1天内 "HH:mm:ss"；超1天 "N天HH:mm:ss"；≥1年 "N年[M天]HH:mm:ss"
//

import XCTest
@testable import SwallowCalendar

final class CountdownFormatterTests: XCTestCase {

    // MARK: - 实时倒计时文案（AC-1~4）

    func testExpired() {
        XCTAssertEqual(CountdownFormatter.formatCountdown(remaining: -10), "已过期")
        XCTAssertEqual(CountdownFormatter.formatCountdown(remaining: 0), "已过期")
    }

    func testSeconds() {
        XCTAssertEqual(CountdownFormatter.formatCountdown(remaining: 59), "00:00:59")
        XCTAssertEqual(CountdownFormatter.formatCountdown(remaining: 59.9), "00:00:59")
    }

    func testMinutes() {
        XCTAssertEqual(CountdownFormatter.formatCountdown(remaining: 60), "00:01:00")
        XCTAssertEqual(CountdownFormatter.formatCountdown(remaining: 61), "00:01:01")
        XCTAssertEqual(CountdownFormatter.formatCountdown(remaining: 3599), "00:59:59")
    }

    func testHours() {
        XCTAssertEqual(CountdownFormatter.formatCountdown(remaining: 3600), "01:00:00")
        XCTAssertEqual(CountdownFormatter.formatCountdown(remaining: 3660), "01:01:00")
        XCTAssertEqual(CountdownFormatter.formatCountdown(remaining: 86399), "23:59:59")
    }

    func testDays() {
        XCTAssertEqual(CountdownFormatter.formatCountdown(remaining: 86400), "1天00:00:00")
        XCTAssertEqual(CountdownFormatter.formatCountdown(remaining: 86400.0 * 2 + 3600), "2天01:00:00")
        XCTAssertEqual(CountdownFormatter.formatCountdown(remaining: 86400.0 * 29 + 32203), "29天08:56:43")
    }

    func testYears() {
        XCTAssertEqual(CountdownFormatter.formatCountdown(remaining: 86400.0 * 365), "1年00:00:00")
        XCTAssertEqual(CountdownFormatter.formatCountdown(remaining: 86400.0 * 366), "1年1天00:00:00")
        XCTAssertEqual(CountdownFormatter.formatCountdown(remaining: 86400.0 * 365 * 2 + 86400 * 5), "2年5天00:00:00")
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
