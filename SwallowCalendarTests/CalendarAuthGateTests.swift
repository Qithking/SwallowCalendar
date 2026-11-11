//
//  CalendarAuthGateTests.swift
//  SwallowCalendarTests
//
//  startup-auth-gate：启动日历授权门决策与授权快照刷新的回归测试。
//  背景：授权请求原先挂在 ContentView.task，而 ContentView 是主面板内容视图——
//  应用启动（菜单栏常驻）面板未展开时视图不存在，授权请求从未执行，
//  应用「从没见过授权弹框」。修复后启动门决策收敛为 shouldGuideCalendarAccess
//  纯函数；设置页快照刷新收敛为 refreshAuthorizationStatus。
//

import XCTest
import EventKit
@testable import SwallowCalendar

final class CalendarAuthGateTests: XCTestCase {

    private let calendarService = CalendarService()

    // MARK: - 启动门决策（日历）

    /// denied：应用内无法再弹系统授权框，启动时应弹引导窗前往系统设置
    func testShouldGuideWhenDenied() {
        XCTAssertTrue(CalendarService.shouldGuideCalendarAccess(.denied))
    }

    /// restricted（家长控制等）系统级受限，同样只能引导前往设置
    func testShouldGuideWhenRestricted() {
        XCTAssertTrue(CalendarService.shouldGuideCalendarAccess(.restricted))
    }

    /// notDetermined：启动时应直接弹系统授权框，不走引导
    func testShouldNotGuideWhenNotDetermined() {
        XCTAssertFalse(CalendarService.shouldGuideCalendarAccess(.notDetermined))
    }

    /// 已授权无需任何授权引导
    func testShouldNotGuideWhenFullAccess() {
        XCTAssertFalse(CalendarService.shouldGuideCalendarAccess(.fullAccess))
    }

    /// writeOnly 同理无需授权引导
    func testShouldNotGuideWhenWriteOnly() {
        XCTAssertFalse(CalendarService.shouldGuideCalendarAccess(.writeOnly))
    }

    // MARK: - 授权快照刷新

    /// 外部状态变化（用户在系统设置改授权）不会自动更新 init 时的快照，
    /// refresh 后快照必须等于 EK 实时值——否则设置页会展示过时状态。
    /// 先污染快照再刷新，避免断言写宽导致恒绿。
    func testRefreshAuthorizationStatusSyncsCalendarSnapshot() {
        let live = EKEventStore.authorizationStatus(for: .event)
        let polluted: EKAuthorizationStatus = live == .denied ? .fullAccess : .denied
        calendarService.authorizationStatus = polluted

        calendarService.refreshAuthorizationStatus()

        XCTAssertEqual(
            calendarService.authorizationStatus,
            EKEventStore.authorizationStatus(for: .event),
            "日历授权快照刷新后必须等于 EK 实时值"
        )
    }

    /// 提醒授权快照同理刷新
    func testRefreshAuthorizationStatusSyncsReminderSnapshot() {
        let live = EKEventStore.authorizationStatus(for: .reminder)
        let polluted: EKAuthorizationStatus = live == .denied ? .fullAccess : .denied
        calendarService.reminderAuthorizationStatus = polluted

        calendarService.refreshAuthorizationStatus()

        XCTAssertEqual(
            calendarService.reminderAuthorizationStatus,
            EKEventStore.authorizationStatus(for: .reminder),
            "提醒授权快照刷新后必须等于 EK 实时值"
        )
    }
}
