//
//  DesktopTodoPanelManagerTests.swift
//  SwallowCalendarTests
//
//  桌面面板窗口行为回归测试
//  bug: desktop-panel-picker-not-clickable——canBecomeKey=false 时 SwiftUI Picker 点击失效
//  （二轮 hitTest 取证结论见 fix artifact：合成事件无法驱动 SwiftUI 内嵌 AppKit 控件，
//   hitTest 拒绝下钻属平台桥接普遍行为，不可作为单测判据）
//

import XCTest
import AppKit
import SwiftUI
@testable import SwallowCalendar

@MainActor
final class DesktopTodoPanelManagerTests: XCTestCase {

    /// canBecomeKey 必须为 true：nonactivating panel 点击不激活应用由 styleMask 保证，
    /// 但 SwiftUI 控件（Picker 等）action 响应链需要窗口可成为 key；
    /// false 会导致面板上 Picker/勾选框点击失效（真机复现 bug）
    func testDesktopPanelCanBecomeKey() {
        let panel = DesktopPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.nonactivatingPanel, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        XCTAssertTrue(panel.canBecomeKey, "canBecomeKey=false 会断掉 Picker 等控件的点击响应链")
        // nonactivating 语义不能丢：点击不激活应用由 styleMask 决定，与 key 无关
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
    }

    /// 层级回归：必须高于壁纸层（同层时点击被系统路由给桌面、面板收不到事件），
    /// 且仍低于普通应用窗口（spec：所有应用窗口之下）
    func testDesktopPanelLevelBetweenWallpaperAndNormal() {
        let wallpaper = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        let panelLevel = DesktopTodoPanelManager.level(isPinned: false)
        XCTAssertGreaterThan(panelLevel, wallpaper)
        XCTAssertLessThan(panelLevel, .normal)
    }

    /// 置顶切换回归（用户需求：点击置顶后不被其他应用遮挡）：
    /// 置顶用 .floating（高于所有普通应用窗口），取消置顶回落 .normal-1
    func testPanelLevelPinnedSwitchesToFloating() {
        XCTAssertEqual(
            DesktopTodoPanelManager.level(isPinned: true),
            .floating,
            "置顶必须 .floating，否则会被普通应用窗口遮挡"
        )
        XCTAssertEqual(
            DesktopTodoPanelManager.level(isPinned: false),
            NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        )
    }
}
