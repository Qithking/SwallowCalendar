//
//  CachedEventReminderOffsetsTests.swift
//  SwallowCalendarTests
//
//  多级提醒偏移量与硬不变量测试（plan 步骤 6 / G1 双向联动）

import XCTest
import SwiftData
import EventKit
@testable import SwallowCalendar

final class CachedEventReminderOffsetsTests: XCTestCase {

    /// 构造测试用 CachedEvent
    private func makeEvent() -> CachedEvent {
        CachedEvent(
            eventID: "test-evt-1",
            title: "测试事项",
            startDate: Date().addingTimeInterval(3600),
            endDate: Date().addingTimeInterval(7200),
            isAllDay: false,
            calendarID: "test",
            calendarTitle: "测试日历",
            calendarColorHex: "#007AFF"
        )
    }

    // MARK: - 读取回退

    func testLegacyNilJSONFallsBackToSingleLevel() {
        let event = makeEvent()
        event.reminderMinutes = 10
        // 未设置多级 JSON：回退单级语义
        XCTAssertEqual(event.reminderOffsets, [10])
    }

    /// BUG-07 已解除：存量 JSON 中 2 天前等长提前量读取时原样保留（安全上限 365 天）
    func testLegacyLongOffsetsPreservedOnRead() {
        let event = makeEvent()
        event.reminderOffsetsJSON = "[2880,0]"
        XCTAssertEqual(event.reminderOffsets, [0, 2880])
    }

    /// BUG-07 已解除：写入 2 天前不再被压成 1 天，reminderMinutes 随之为 2880
    func testLongOffsetsPreservedOnWrite() {
        let event = makeEvent()
        event.reminderOffsets = [2880, 0]
        XCTAssertEqual(event.reminderOffsets, [0, 2880])
        XCTAssertEqual(event.reminderMinutes, 2880)
    }

    func testCorruptJSONFallsBackToSingleLevel() {
        let event = makeEvent()
        event.reminderMinutes = 10
        event.reminderOffsetsJSON = "not-json"
        XCTAssertEqual(event.reminderOffsets, [10])
    }

    // MARK: - setter 与硬不变量

    func testOffsetsSetterWritesMaxToMinutes() {
        let event = makeEvent()
        event.reminderOffsets = [10, 1440, 5]
        // 硬不变量 reminderMinutes == offsets.max()，且去重升序存储
        XCTAssertEqual(event.reminderOffsets, [5, 10, 1440])
        XCTAssertEqual(event.reminderMinutes, 1440)
        XCTAssertNotNil(event.reminderOffsetsJSON)
    }

    func testMinutesDirectAssignRewritesMax() {
        let event = makeEvent()
        event.reminderOffsets = [5, 10, 60]
        // G1：直赋 minutes 语义为"最高档被改为新值"（@Model 宏不保留 didSet，
        // 反向重写经显式方法 setReminderMinutesRewritingMax 承担）
        event.setReminderMinutesRewritingMax(30)
        XCTAssertEqual(event.reminderOffsets, [5, 10, 30])
        XCTAssertEqual(event.reminderMinutes, 30)
    }

    func testMinutesDirectAssignDedupesAfterRewrite() {
        let event = makeEvent()
        event.reminderOffsets = [5, 30, 60]
        event.setReminderMinutesRewritingMax(30)
        // 旧 max 60 替换为 30 后与新档 30 重复，去重后不破坏不变量
        XCTAssertEqual(event.reminderOffsets, [5, 30])
        XCTAssertEqual(event.reminderMinutes, 30)
    }

    func testMinutesAssignMatchingMaxNoRewrite() {
        let event = makeEvent()
        event.reminderOffsets = [10, 60]
        let jsonBefore = event.reminderOffsetsJSON
        event.setReminderMinutesRewritingMax(60)
        // max 未失配：JSON 不重写
        XCTAssertEqual(event.reminderOffsetsJSON, jsonBefore)
        XCTAssertEqual(event.reminderOffsets, [10, 60])
    }

    // MARK: - 清空语义

    func testEmptyArrayClearsJSONAndMinutes() {
        let event = makeEvent()
        event.reminderMinutes = 20
        event.reminderOffsets = [5, 10]
        event.reminderOffsets = []
        // 空数组 = 无提前提醒：清空 JSON 且 reminderMinutes 归零，getter 返回 []
        XCTAssertNil(event.reminderOffsetsJSON)
        XCTAssertEqual(event.reminderMinutes, 0)
        XCTAssertEqual(event.reminderOffsets, [])
    }

    // MARK: - EKAlarm 提取（步骤 7）

    func testExtractOffsetsFromAlarms() {
        // 多 alarm：去重升序提取完整数组
        let alarms = [
            EKAlarm(relativeOffset: -600),   // 10 分钟
            EKAlarm(relativeOffset: -86400), // 1 天
            EKAlarm(relativeOffset: -300),   // 5 分钟
            EKAlarm(relativeOffset: -600),   // 与第一档重复
        ]
        XCTAssertEqual(CalendarService.extractReminderOffsets(from: alarms), [5, 10, 1440])
    }

    func testExtractOffsetsAcceptsZeroAndAfter() {
        // absolute 不反推；0=到点、正 relativeOffset=延后 均属于有符号偏移
        let absolute = EKAlarm(absoluteDate: Date().addingTimeInterval(3600))
        let zero = EKAlarm(relativeOffset: 0)
        let after = EKAlarm(relativeOffset: 60)
        XCTAssertEqual(CalendarService.extractReminderOffsets(from: [absolute, zero, after]), [-1, 0])
        XCTAssertNil(CalendarService.extractReminderOffsets(from: [absolute]))
        XCTAssertNil(CalendarService.extractReminderOffsets(from: nil))
    }

    func testExtractOffsetsSingleAlarm() {
        let alarms = [EKAlarm(relativeOffset: -1800)]
        XCTAssertEqual(CalendarService.extractReminderOffsets(from: alarms), [30])
    }
}
