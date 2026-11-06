//
//  ReminderAlertKeyTests.swift
//  SwallowCalendarTests
//
//  去重键编解码与旧格式惰性兼容测试（plan 步骤 5 / AC-7）

import XCTest
@testable import SwallowCalendar

@MainActor
final class ReminderAlertKeyTests: XCTestCase {

    func testEncodeDecodeRoundTrip() {
        let alertTime = Date(timeIntervalSince1970: 1_760_000_000)
        let key = ReminderAlertKey(eventID: "evt-123", alertTime: alertTime)
        let decoded = ReminderAlertKey(raw: key.encoded)
        XCTAssertEqual(decoded?.eventID, "evt-123")
        XCTAssertEqual(decoded?.alertTime, alertTime)
    }

    func testEncodedFormat() {
        let key = ReminderAlertKey(eventID: "evt-1", alertTime: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(key.encoded, "evt-1|100")
    }

    func testLegacyKeyWithoutTimestampIsRejected() {
        // BUG-03：旧格式（无 "|"）不再惰性兼容为 .distantPast 通配，
        // 否则任意一期都会被判定为"已提醒"导致整条序列永久静默
        XCTAssertNil(ReminderAlertKey(raw: "evt-legacy"))
    }

    func testEventIDContainingSeparator() {
        // eventID 理论上不含 "|"，即使含也安全：解码取末段 "|" 之后为时间戳（lastIndex 分割）
        let alertTime = Date(timeIntervalSince1970: 42)
        let key = ReminderAlertKey(eventID: "ics-http://a|b-hash", alertTime: alertTime)
        let decoded = ReminderAlertKey(raw: key.encoded)
        XCTAssertEqual(decoded?.eventID, "ics-http://a|b-hash")
        XCTAssertEqual(decoded?.alertTime, alertTime)
    }

    func testMalformedTimestampIsRejected() {
        // BUG-03：末段非数字 → nil（由启动迁移丢弃），不崩溃也不通配
        XCTAssertNil(ReminderAlertKey(raw: "evt-2|not-a-number"))
    }

    // MARK: - BUG-03 启动迁移

    func testSanitizeDropsLegacyKeys() {
        let saved = ["evt-legacy", "evt-1|100", "evt-2|bad", "base|occ:200|300"]
        let sanitized = ReminderAlertService.sanitizedAlertedEventIDs(saved)
        XCTAssertEqual(sanitized, ["evt-1|100", "base|occ:200|300"])
    }

    // MARK: - 重复提醒边界（2026-11-06 口径：自动重提醒已移除）

    private let snoozeRecordsKey = "ReminderAlertService.snoozeRecords"

    /// 用户主动「稍后提醒」仍入队（保留用户意图）：fireDate = now + minutes
    func testUserSnoozeEnqueuesRecord() {
        UserDefaults.standard.removeObject(forKey: snoozeRecordsKey)
        defer { UserDefaults.standard.removeObject(forKey: snoozeRecordsKey) }
        let before = Date()
        ReminderAlertService.shared.snooze(eventID: "user-snooze", minutes: 10)
        let records = ReminderAlertService.loadSnoozeRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.eventID, "user-snooze")
        XCTAssertEqual(
            records.first?.fireDate.timeIntervalSince(before) ?? 0,
            600,
            accuracy: 5,
            "用户主动稍后提醒 10 分钟应入队且不被自动重提醒逻辑改写"
        )
    }
}
