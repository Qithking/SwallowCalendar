//
//  PanelDisplayModeTests.swift
//  SwallowCalendarTests
//
//  显示待办面板模式回归测试
//  需求：设置「桌面显示待办面板」改为下拉「显示待办面板」四态
//  （无/菜单栏图标/桌面面板/两者）——菜单栏图标档控制 hover 弹层，
//  桌面面板档控制常驻面板；旧 Bool 开关迁移（true→两者保持现有行为，
//  false→菜单栏图标保持 hover 弹层现状）+ 两派生旗标
//

import XCTest
@testable import SwallowCalendar

@MainActor
final class PanelDisplayModeTests: XCTestCase {

    /// 旧 Bool 开关迁移：true（面板开）→ 两者；false（面板关）→ 菜单栏图标
    ///（hover 弹层历史上不受开关控制，迁移后保持可见——升级用户行为零回归）
    func testLegacyMigration() {
        XCTAssertEqual(AppSettings.TodoPanelDisplayMode.fromLegacy(enabled: true), .both)
        XCTAssertEqual(AppSettings.TodoPanelDisplayMode.fromLegacy(enabled: false), .menuBarIcon)
    }

    /// 菜单栏图标旗标：菜单栏图标档与两者档开启；无/桌面面板档关闭
    func testMenuBarHoverFlag() {
        XCTAssertTrue(AppSettings.TodoPanelDisplayMode.menuBarIcon.menuBarHoverEnabled)
        XCTAssertTrue(AppSettings.TodoPanelDisplayMode.both.menuBarHoverEnabled)
        XCTAssertFalse(AppSettings.TodoPanelDisplayMode.none.menuBarHoverEnabled)
        XCTAssertFalse(AppSettings.TodoPanelDisplayMode.desktopPanel.menuBarHoverEnabled)
    }

    /// 桌面面板旗标：桌面面板档与两者档开启；无/菜单栏图标档关闭
    func testDesktopPanelFlag() {
        XCTAssertTrue(AppSettings.TodoPanelDisplayMode.desktopPanel.desktopPanelEnabled)
        XCTAssertTrue(AppSettings.TodoPanelDisplayMode.both.desktopPanelEnabled)
        XCTAssertFalse(AppSettings.TodoPanelDisplayMode.none.desktopPanelEnabled)
        XCTAssertFalse(AppSettings.TodoPanelDisplayMode.menuBarIcon.desktopPanelEnabled)
    }

    /// 四态中文展示名（设置下拉用）
    func testDisplayTitles() {
        XCTAssertEqual(AppSettings.TodoPanelDisplayMode.none.displayTitle, "无")
        XCTAssertEqual(AppSettings.TodoPanelDisplayMode.menuBarIcon.displayTitle, "菜单栏图标")
        XCTAssertEqual(AppSettings.TodoPanelDisplayMode.desktopPanel.displayTitle, "桌面面板")
        XCTAssertEqual(AppSettings.TodoPanelDisplayMode.both.displayTitle, "两者")
    }
}
