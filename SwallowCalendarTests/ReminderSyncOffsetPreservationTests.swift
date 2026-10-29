//
//  ReminderSyncOffsetPreservationTests.swift
//  SwallowCalendarTests
//
//  bug: reminder-offsets-wiped-by-sync——EKReminder absolute 准点闹钟（任务 E 模式）
//  回流 sync 时不得冲掉缓存提前提醒（提前提醒真源为缓存 reminderOffsets）

import XCTest
import SwiftData
import EventKit
@testable import SwallowCalendar

final class ReminderSyncOffsetPreservationTests: XCTestCase {

    /// 构造既有缓存行：用户设置了提前 10/30 分钟提醒
    private func makeExisting() -> CachedEvent {
        let cached = CachedEvent(
            eventID: "rem-1",
            title: "测试提醒",
            startDate: Date().addingTimeInterval(3600),
            endDate: Date().addingTimeInterval(3600),
            isAllDay: false,
            calendarID: "reminder",
            calendarTitle: "提醒",
            calendarColorHex: "#FF9500",
            isReminder: true
        )
        cached.reminderOffsets = [10, 30]
        return cached
    }

    /// 构造 EK 回流映射行（同 syncReminders 循环输入）
    private func makeEK(offsets: [Int]?, minutes: Int, alarmIsAbsolute: Bool) -> CalendarEvent {
        CalendarEvent(
            id: "rem-1",
            title: "测试提醒",
            startDate: Date().addingTimeInterval(3600),
            endDate: Date().addingTimeInterval(3600),
            isAllDay: false,
            calendarID: "reminder",
            calendarTitle: "提醒",
            calendarColorHex: "#FF9500",
            category: .user,
            isCompleted: false,
            priority: 0,
            isReminder: true,
            recurrenceType: .none,
            reminderMinutes: minutes,
            reminderOffsets: offsets,
            reminderAlarmIsAbsolute: alarmIsAbsolute,
            eventColorHex: nil
        )
    }

    // V-1：absolute 准点闹钟（任务 E 模式）回流，缓存提前提醒必须保留
    @MainActor
    func testSyncUpdateKeepsCachedOffsetsWhenEKAlarmIsAbsolute() {
        let existing = makeExisting()
        // EK 侧 absolute(due) 不携带提前量：extract 解析为 offsets=nil、minutes=0
        let ek = makeEK(offsets: nil, minutes: 0, alarmIsAbsolute: true)

        EventCacheService.mergeReminderUpdate(existing: existing, ek: ek)

        XCTAssertEqual(existing.reminderOffsets, [10, 30], "absolute 准点闹钟不携带提前量，sync 不得用空值覆盖缓存提前提醒")
        XCTAssertEqual(existing.reminderMinutes, 30)
    }

    // 对照：relative 闹钟照常采纳 EK 值（B-8 语义：EK 侧为准，不回退）
    @MainActor
    func testSyncUpdateAdoptsEKOffsetsWhenAlarmIsRelative() {
        let existing = makeExisting()
        let ek = makeEK(offsets: [15], minutes: 15, alarmIsAbsolute: false)

        EventCacheService.mergeReminderUpdate(existing: existing, ek: ek)

        XCTAssertEqual(existing.reminderOffsets, [15], "relative 闹钟可解析提前量，照常采纳 EK 值")
        XCTAssertEqual(existing.reminderMinutes, 15)
    }

    // 判定来源：hasAbsoluteReminderAlarm 四类闹钟判定
    func testHasAbsoluteReminderAlarmDetection() {
        XCTAssertTrue(CalendarService.hasAbsoluteReminderAlarm([EKAlarm(absoluteDate: Date())]))
        XCTAssertFalse(CalendarService.hasAbsoluteReminderAlarm([EKAlarm(relativeOffset: -300)]))
        XCTAssertFalse(CalendarService.hasAbsoluteReminderAlarm(nil))
        // 混合：含任一 absolute 即按应用准点闹钟模式处理
        XCTAssertTrue(CalendarService.hasAbsoluteReminderAlarm([EKAlarm(relativeOffset: -300), EKAlarm(absoluteDate: Date())]))
    }
}
