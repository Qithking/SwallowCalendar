//
//  DesktopPanelVisibilityTests.swift
//  SwallowCalendarTests
//
//  bug: desktop-panel-hidden-reload——桌面面板 orderOut 后 SwiftUI 视图不销毁，
//  cachedEventsChanged/countdownExpired 通知仍触发 reload 查库；
//  面板不可见（未创建/orderOut）时 Manager.isPanelVisible 必须 false 供视图守卫跳过查询
//

import XCTest
@testable import SwallowCalendar

@MainActor
final class DesktopPanelVisibilityTests: XCTestCase {

    // V-1: 面板未创建（默认态）时不可见——隐藏守卫默认生效，通知触发的 reload 被跳过
    func testPanelVisibilityDefaultsToHiddenBeforeCreation() {
        XCTAssertFalse(DesktopTodoPanelManager.shared.isPanelVisible,
                       "面板未创建时 isPanelVisible 应为 false（守卫跳过 reload 查库）")
    }
}
