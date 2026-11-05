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

    // MARK: - BUG-04 五分钟重提醒

    func testRetryRecordsEnqueueStartedUncompletedEvent() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let started = (eventID: "started", startDate: now.addingTimeInterval(-60), isCompleted: false)
        let records = ReminderAlertService.nextRetryRecords(for: [started], now: now, existing: [])
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.eventID, "started")
        XCTAssertEqual(
            records.first?.fireDate,
            now.addingTimeInterval(ReminderAlertService.retryInterval)
        )
    }

    func testRetryRecordsSkipFutureAndCompletedEvents() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let future = (eventID: "future", startDate: now.addingTimeInterval(3600), isCompleted: false)
        let completed = (eventID: "completed", startDate: now.addingTimeInterval(-60), isCompleted: true)
        let records = ReminderAlertService.nextRetryRecords(
            for: [future, completed],
            now: now,
            existing: []
        )
        XCTAssertTrue(records.isEmpty, "未开始（提前档）与已完成的事件不得入队")
    }

    func testRetryRecordsDoNotOverrideExistingSnooze() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let userSnooze = SnoozeRecord(eventID: "started", fireDate: now.addingTimeInterval(600))
        let started = (eventID: "started", startDate: now.addingTimeInterval(-60), isCompleted: false)
        let records = ReminderAlertService.nextRetryRecords(
            for: [started],
            now: now,
            existing: [userSnooze]
        )
        XCTAssertEqual(records, [userSnooze], "用户设置的稍后提醒不被自动重提醒覆盖")
    }
}
