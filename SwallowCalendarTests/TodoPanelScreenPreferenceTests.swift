//
//  TodoPanelScreenPreferenceTests.swift
//  SwallowCalendarTests
//
//  桌面待办面板显示屏幕偏好（2026-11-12）：
//  设置页「显示待办面板」选桌面/两者时新增「待办面板显示屏幕」下拉（默认主屏幕），
//  桌面面板按所选屏幕显示。测试锁定屏幕解析纯函数与设置持久化。
//

import XCTest
@testable import SwallowCalendar

@MainActor
final class TodoPanelScreenPreferenceTests: XCTestCase {

    // MARK: - 屏幕解析纯函数

    /// preferredID 匹配某屏的 displayID → 返回该屏
    func testTargetScreenMatchesPreferredID() throws {
        let screens = NSScreen.screens
        let first = try XCTUnwrap(screens.first, "测试环境应至少有一块屏幕")
        let id = try XCTUnwrap(DesktopTodoPanelManager.displayID(of: first), "NSScreen 应携带 NSScreenNumber")

        let resolved = DesktopTodoPanelManager.targetScreen(preferredID: String(id), screens: screens)
        XCTAssertEqual(resolved, first)
    }

    /// preferredID 未匹配任何屏 → nil（调用方回退主屏幕）
    func testTargetScreenReturnsNilForUnknownID() {
        XCTAssertNil(
            DesktopTodoPanelManager.targetScreen(preferredID: "999999999", screens: NSScreen.screens)
        )
    }

    /// preferredID 为空串（默认值=未选择）→ nil，面板回退主屏幕
    func testTargetScreenReturnsNilForEmptyID() {
        XCTAssertNil(
            DesktopTodoPanelManager.targetScreen(preferredID: "", screens: NSScreen.screens)
        )
    }

    // MARK: - 设置持久化

    /// todoPanelScreenID didSet 写入 UserDefaults（didSet 同时联动面板重定位，实机核对）
    func testScreenIDPersistsToUserDefaults() {
        AppSettings.shared.todoPanelScreenID = "screen-under-test"
        XCTAssertEqual(UserDefaults.standard.string(forKey: "todoPanelScreenID"), "screen-under-test")
        // 还原默认值（空串=主屏幕），避免污染其他用例
        AppSettings.shared.todoPanelScreenID = ""
    }
}
