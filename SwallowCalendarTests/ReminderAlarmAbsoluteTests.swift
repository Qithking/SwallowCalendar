//
//  ReminderAlarmAbsoluteTests.swift
//  SwallowCalendarTests
//
//  bug: reminder-app-shows-advanced-time（方案 B，2026-11-07 用户重申）
//  需求：应用创建「提醒 T + 提前 N 分钟」同步到系统提醒 app 后，
//        系统 app 显示的到期时间应为设定时间 T（准点），而非 T-offset
//  方案 B：EKReminder 路径对齐 Apple 自家存储模式——系统侧写 absolute(due) 准点闹钟，
//        提前提醒由应用内缓存 reminderOffsets 承担（ReminderAlertService 按 due-offset
//        提前弹窗）；EKEvent 事件路径保持 relative 闹钟语义（执行文档编码要求）
//

import XCTest
import EventKit
@testable import SwallowCalendar

final class ReminderAlarmAbsoluteTests: XCTestCase {

    /// 固定锚点时间，避免时区/当前时刻波动
    private let due = Date(timeIntervalSince1970: 1_793_260_000)

    // MARK: - EKReminder 路径（reminderDueDate 非空）

    /// R-1: 提醒路径带多级提前量 → 系统侧唯一闹钟为 absolute(due) 准点
    /// （防回归核心：带 offset 的事项写出的 EK 闹钟触发日期 == due 准点，offset 绝不写入 EK）
    func testReminderAlarmWithOffsetsUsesAbsoluteDue() {
        let alarms = CalendarService.makeAlarms(offsets: [5], minutes: nil, reminderDueDate: due)
        XCTAssertEqual(alarms.count, 1, "系统侧只保留一条准点闹钟")
        XCTAssertEqual(alarms[0].absoluteDate, due, "带 offset 写出的 EK 闹钟触发日期必须 == due 准点")
        XCTAssertEqual(alarms[0].relativeOffset, 0, "不写相对偏移（系统 app 会渲染为 T-offset）")
    }

    /// R-1b: 提醒路径延后档（负 offset）同样只写准点绝对闹钟，不得逐档写相对闹钟
    func testReminderAlarmWithAfterOffsetStillAbsoluteDue() {
        let alarms = CalendarService.makeAlarms(offsets: [-60], minutes: nil, reminderDueDate: due)
        XCTAssertEqual(alarms.count, 1)
        XCTAssertEqual(alarms[0].absoluteDate, due, "延后档同样只写准点绝对闹钟")
        XCTAssertEqual(alarms[0].relativeOffset, 0)
    }

    /// R-2: 提醒路径单级 minutes 兼容口径 → 同样只写 absolute(due)
    func testReminderAlarmWithMinutesUsesAbsoluteDue() {
        let alarms = CalendarService.makeAlarms(offsets: nil, minutes: 10, reminderDueDate: due)
        XCTAssertEqual(alarms.count, 1)
        XCTAssertEqual(alarms[0].absoluteDate, due)
        XCTAssertEqual(alarms[0].relativeOffset, 0)
    }

    /// R-3: 提醒路径未设置提前提醒 → 不写系统提前闹钟
    func testReminderAlarmWithoutAdvanceKeepsEmpty() {
        let alarms = CalendarService.makeAlarms(offsets: nil, minutes: 0, reminderDueDate: due)
        XCTAssertTrue(alarms.isEmpty, "无提前提醒时保持无提前闹钟")
    }

    /// R-5: absolute 闹钟仍不被反推为相对档位（兼容 Apple 原生绝对闹钟回流）
    func testExtractOffsetsIgnoresAbsoluteAlarm() {
        let absoluteOnly = [EKAlarm(absoluteDate: due)]
        XCTAssertNil(
            CalendarService.extractReminderOffsets(from: absoluteOnly),
            "absolute 闹钟不应被反推为相对偏移档位"
        )
    }

    // MARK: - EKEvent 路径（reminderDueDate 为空，回归保护）

    /// R-4: 事件路径保持相对偏移闹钟，系统日历通知仍按提前量触发
    func testEventAlarmKeepsRelativeOffsets() {
        let alarms = CalendarService.makeAlarms(offsets: [5, 10], minutes: nil, reminderDueDate: nil)
        XCTAssertEqual(alarms.count, 2)
        XCTAssertEqual(alarms.map { Int(-$0.relativeOffset / 60) }, [5, 10], "事件路径保持相对偏移语义")
    }

    /// R-6: 事件路径单级 minutes 口径不变
    func testEventAlarmKeepsRelativeMinutes() {
        let alarms = CalendarService.makeAlarms(offsets: nil, minutes: 15, reminderDueDate: nil)
        XCTAssertEqual(alarms.count, 1)
        XCTAssertEqual(Int(-alarms[0].relativeOffset / 60), 15)
        XCTAssertNil(alarms[0].absoluteDate)
    }
}
