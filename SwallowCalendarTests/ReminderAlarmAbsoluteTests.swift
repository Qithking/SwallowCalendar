//
//  ReminderAlarmAbsoluteTests.swift
//  SwallowCalendarTests
//
//  bug: reminder-app-shows-advanced-time
//  需求：应用创建「提醒 T + 提前 5 分钟」同步到系统提醒 app 后，
//        系统 app 列表/详情显示的到期时间应为设定时间 T，而非 T-5min
//  根因：应用向 EKReminder 写 relative(-offset) 相对闹钟，
//        macOS 提醒 app 将其渲染为「提醒我 T-offset」单一告警
//        （EventKit 读回实验证实：落库 due=21:38 + rel(-300) 正确，
//         系统 app 显示 21:33；Apple 自建提醒用 due=T + absolute(T) 模式）
//  修复：EKReminder 路径对齐 Apple 自家存储模式——系统侧写 absolute(due) 准点闹钟，
//        提前提醒由应用内缓存 reminderOffsets 承担（缓存无 EK 回填覆盖点，不丢失）
//

import XCTest
import EventKit
@testable import SwallowCalendar

final class ReminderAlarmAbsoluteTests: XCTestCase {

    /// 固定锚点时间，避免时区/当前时刻波动
    private let due = Date(timeIntervalSince1970: 1_793_260_000)

    // MARK: - EKReminder 路径（reminderDueDate 非空）

    /// R-1: 提醒路径带多级提前量 → 系统侧唯一闹钟为 absolute(due) 准点，不再产生相对偏移
    func testReminderAlarmWithOffsetsUsesAbsoluteDue() {
        let alarms = CalendarService.makeAlarms(offsets: [5], minutes: nil, reminderDueDate: due)
        XCTAssertEqual(alarms.count, 1, "系统侧只保留一条准点闹钟")
        XCTAssertEqual(alarms[0].absoluteDate, due, "闹钟应为 due 时刻的绝对闹钟")
        XCTAssertEqual(alarms[0].relativeOffset, 0, "不应再写相对偏移（系统 app 会渲染为 T-offset）")
    }

    /// R-2: 提醒路径单级 minutes 兼容口径 → 同样写 absolute(due)
    func testReminderAlarmWithMinutesUsesAbsoluteDue() {
        let alarms = CalendarService.makeAlarms(offsets: nil, minutes: 10, reminderDueDate: due)
        XCTAssertEqual(alarms.count, 1)
        XCTAssertEqual(alarms[0].absoluteDate, due)
        XCTAssertEqual(alarms[0].relativeOffset, 0)
    }

    /// R-3: 提醒路径未设置提前提醒 → 不写系统闹钟（保持原行为，不引入准点通知变化）
    func testReminderAlarmWithoutAdvanceKeepsEmpty() {
        let alarms = CalendarService.makeAlarms(offsets: nil, minutes: 0, reminderDueDate: due)
        XCTAssertTrue(alarms.isEmpty, "无提前提醒时保持无系统闹钟")
    }

    /// R-5: 改造后提醒闹钟不再被读取侧识别为相对偏移
    /// （应用内提前提醒的 source of truth 是缓存 reminderOffsets，非 EK 闹钟反推）
    func testExtractOffsetsIgnoresAbsoluteAlarm() {
        let alarms = CalendarService.makeAlarms(offsets: [5], minutes: nil, reminderDueDate: due)
        XCTAssertNil(
            CalendarService.extractReminderOffsets(from: alarms),
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
