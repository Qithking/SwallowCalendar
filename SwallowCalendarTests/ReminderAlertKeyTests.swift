//
//  ReminderAlertKeyTests.swift
//  SwallowCalendarTests
//
//  去重键编解码与旧格式惰性兼容测试（plan 步骤 5 / AC-7）

import XCTest
@testable import SwallowCalendar

final class ReminderAlertKeyTests: XCTestCase {

    func testEncodeDecodeRoundTrip() {
        let alertTime = Date(timeIntervalSince1970: 1_760_000_000)
        let key = ReminderAlertKey(eventID: "evt-123", alertTime: alertTime)
        let decoded = ReminderAlertKey(raw: key.encoded)
        XCTAssertEqual(decoded.eventID, "evt-123")
        XCTAssertEqual(decoded.alertTime, alertTime)
    }

    func testEncodedFormat() {
        let key = ReminderAlertKey(eventID: "evt-1", alertTime: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(key.encoded, "evt-1|100")
    }

    func testLegacyKeyCompat() {
        // 旧格式（无 "|"，仅 eventID）：惰性兼容为 (eventID, .distantPast)，
        // 语义为"该事件已提醒过"，匹配任意 alertTime
        let decoded = ReminderAlertKey(raw: "evt-legacy")
        XCTAssertEqual(decoded.eventID, "evt-legacy")
        XCTAssertEqual(decoded.alertTime, .distantPast)
    }

    func testEventIDContainingSeparator() {
        // eventID 理论上不含 "|"，即使含也安全：解码取末段 "|" 之后为时间戳（lastIndex 分割）
        let alertTime = Date(timeIntervalSince1970: 42)
        let key = ReminderAlertKey(eventID: "ics-http://a|b-hash", alertTime: alertTime)
        let decoded = ReminderAlertKey(raw: key.encoded)
        XCTAssertEqual(decoded.eventID, "ics-http://a|b-hash")
        XCTAssertEqual(decoded.alertTime, alertTime)
    }

    func testMalformedTimestampFallsBackToLegacy() {
        // 时间戳段非法时按旧格式兼容处理，不崩溃
        let decoded = ReminderAlertKey(raw: "evt-2|not-a-number")
        XCTAssertEqual(decoded.eventID, "evt-2|not-a-number")
        XCTAssertEqual(decoded.alertTime, .distantPast)
    }
}
