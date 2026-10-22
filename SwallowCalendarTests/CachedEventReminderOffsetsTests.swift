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
        // G1：既有 reminderMinutes 直赋值点（同步/创建路径）反向重写 offsets，
        // 语义为"最高档被改为新值"
        event.reminderMinutes = 30
        XCTAssertEqual(event.reminderOffsets, [5, 10, 30])
        XCTAssertEqual(event.reminderMinutes, 30)
    }

    func testMinutesDirectAssignDedupesAfterRewrite() {
        let event = makeEvent()
        event.reminderOffsets = [5, 30, 60]
        event.reminderMinutes = 30
        // 旧 max 60 替换为 30 后与新档 30 重复，去重后不破坏不变量
        XCTAssertEqual(event.reminderOffsets, [5, 30])
        XCTAssertEqual(event.reminderMinutes, 30)
    }

    func testMinutesAssignMatchingMaxNoRewrite() {
        let event = makeEvent()
        event.reminderOffsets = [10, 60]
        let jsonBefore = event.reminderOffsetsJSON
        event.reminderMinutes = 60
        // max 未失配：JSON 不重写
        XCTAssertEqual(event.reminderOffsetsJSON, jsonBefore)
        XCTAssertEqual(event.reminderOffsets, [10, 60])
    }

    // MARK: - 清空语义

    func testEmptyArrayClearsJSONKeepsMinutes() {
        let event = makeEvent()
        event.reminderMinutes = 20
        event.reminderOffsets = [5, 10]
        event.reminderOffsets = []
        // 空数组：清空多级 JSON，回退单级语义；reminderMinutes 保持 setter 最后写入的 max
        XCTAssertNil(event.reminderOffsetsJSON)
        XCTAssertEqual(event.reminderMinutes, 10)
        XCTAssertEqual(event.reminderOffsets, [10])
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

    func testExtractOffsetsIgnoresNonRelativeAlarms() {
        // 仅有 absoluteDate 型 alarm / 零偏移 / 之后提醒时：无可换算提前量，返回 nil
        let absolute = EKAlarm(absoluteDate: Date().addingTimeInterval(3600))
        let zero = EKAlarm(relativeOffset: 0)
        let after = EKAlarm(relativeOffset: 60)
        XCTAssertNil(CalendarService.extractReminderOffsets(from: [absolute, zero, after]))
        XCTAssertNil(CalendarService.extractReminderOffsets(from: nil))
    }

    func testExtractOffsetsSingleAlarm() {
        let alarms = [EKAlarm(relativeOffset: -1800)]
        XCTAssertEqual(CalendarService.extractReminderOffsets(from: alarms), [30])
    }
}
