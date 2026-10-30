//
//  ReminderAuthPromptTests.swift
//  SwallowCalendarTests
//
//  reminder-auth-prompt：启动/开关路径的提醒权限请求决策回归测试。
//  背景：日历已授权而提醒权限 notDetermined 时，启动链路（仅日历 notDetermined
//  才走 requestAccess）与设置页开关（纯绑定无请求）均不触发提醒授权请求，
//  权限永久卡死 → 提醒同步（== .fullAccess 条件）静默失效。
//

import XCTest
import EventKit
@testable import SwallowCalendar

final class ReminderAuthPromptTests: XCTestCase {

    // MARK: - 启动路径决策

    /// bug 场景核心：开关已开启 + 提醒从未询问 → 启动时应主动补弹系统授权
    func testShouldRequestWhenSyncEnabledAndNotDetermined() {
        XCTAssertTrue(
            CalendarService.shouldRequestReminderAccess(syncEnabled: true, reminderAuth: .notDetermined)
        )
    }

    /// S-7 语义：提醒同步关闭时不应索要提醒 fullAccess
    func testShouldNotRequestWhenSyncDisabled() {
        XCTAssertFalse(
            CalendarService.shouldRequestReminderAccess(syncEnabled: false, reminderAuth: .notDetermined)
        )
    }

    /// 已授权无需请求
    func testShouldNotRequestWhenFullAccess() {
        XCTAssertFalse(
            CalendarService.shouldRequestReminderAccess(syncEnabled: true, reminderAuth: .fullAccess)
        )
    }

    /// denied 由启动引导弹窗与设置页「前往设置」承接，不走系统授权请求
    func testShouldNotRequestWhenDenied() {
        XCTAssertFalse(
            CalendarService.shouldRequestReminderAccess(syncEnabled: true, reminderAuth: .denied)
        )
    }

    /// writeOnly 具备同步读取之外的写入能力但不满足 fullAccess 同步条件，
    /// 交由设置页权限状态提示引导，不做系统授权请求
    func testShouldNotRequestWhenWriteOnly() {
        XCTAssertFalse(
            CalendarService.shouldRequestReminderAccess(syncEnabled: true, reminderAuth: .writeOnly)
        )
    }

    /// restricted（家长控制等）系统级受限，请求无效
    func testShouldNotRequestWhenRestricted() {
        XCTAssertFalse(
            CalendarService.shouldRequestReminderAccess(syncEnabled: true, reminderAuth: .restricted)
        )
    }
}
