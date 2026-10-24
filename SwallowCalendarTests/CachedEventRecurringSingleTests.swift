//
//  CachedEventRecurringSingleTests.swift
//  SwallowCalendarTests
//
//  循环任务单条化 Behavior 1：完成历史字段编解码 + 复合 occurrence ID helper
//  Source: plan/recurring-task-single-record.md step 1+2

import XCTest
import SwiftData
@testable import SwallowCalendar

final class CachedEventRecurringSingleTests: XCTestCase {

    /// 构造测试用单条循环任务
    private func makeRecurringEvent() -> CachedEvent {
        CachedEvent(
            eventID: "rec-base-1",
            title: "每天9点上班",
            startDate: Date(timeIntervalSince1970: 1_760_000_000),
            endDate: Date(timeIntervalSince1970: 1_760_000_000),
            isAllDay: false,
            calendarID: "test",
            calendarTitle: "测试日历",
            calendarColorHex: "#007AFF",
            recurrenceType: .daily
        )
    }

    // MARK: - 完成历史（completedOccurrenceDates）

    func testEmptyHistoryReturnsEmptyArray() {
        let event = makeRecurringEvent()
        // 默认无完成历史
        XCTAssertEqual(event.completedOccurrenceDates, [])
        XCTAssertNil(event.completedOccurrenceDatesJSON)
    }

    func testSetterSortsAndDeduplicates() {
        let event = makeRecurringEvent()
        let d1 = Date(timeIntervalSince1970: 1_760_000_000)
        let d2 = Date(timeIntervalSince1970: 1_760_086_400)
        let d3 = Date(timeIntervalSince1970: 1_760_172_800)
        // 乱序 + 重复写入
        event.completedOccurrenceDates = [d3, d1, d2, d1]
        // 读出升序去重，JSON 已持久化
        XCTAssertEqual(event.completedOccurrenceDates, [d1, d2, d3])
        XCTAssertNotNil(event.completedOccurrenceDatesJSON)
    }

    func testCorruptJSONReturnsEmptyArray() {
        let event = makeRecurringEvent()
        event.completedOccurrenceDatesJSON = "not-json"
        // 坏数据容错回退空数组（不崩溃）
        XCTAssertEqual(event.completedOccurrenceDates, [])
    }

    func testEmptyArrayClearsJSON() {
        let event = makeRecurringEvent()
        event.completedOccurrenceDates = [Date(timeIntervalSince1970: 1_760_000_000)]
        XCTAssertNotNil(event.completedOccurrenceDatesJSON)
        // 空数组 = 清除历史语义
        event.completedOccurrenceDates = []
        XCTAssertNil(event.completedOccurrenceDatesJSON)
    }

    // MARK: - 复合 occurrence ID

    func testOccurrenceIDRoundTrip() {
        let occ = Date(timeIntervalSince1970: 1_760_086_400)
        let compositeID = CachedEvent.makeOccurrenceID(baseID: "rec-base-1", occurrence: occ)
        // 格式契约：<baseID>|occ:<epoch>
        XCTAssertTrue(compositeID.hasPrefix("rec-base-1|occ:"))
        let parsed = CachedEvent.parseOccurrenceID(compositeID)
        XCTAssertEqual(parsed?.baseID, "rec-base-1")
        XCTAssertEqual(parsed?.occurrence.timeIntervalSince1970 ?? 0, occ.timeIntervalSince1970, accuracy: 0.001)
    }

    func testParsePlainEventIDReturnsNil() {
        // 普通 eventID（UUID 等）不含 occ 标记，解析返回 nil
        XCTAssertNil(CachedEvent.parseOccurrenceID("A1B2C3D4-E5F6-4789-A0B1-C2D3E4F5A6B7"))
        XCTAssertNil(CachedEvent.parseOccurrenceID(""))
    }
}
