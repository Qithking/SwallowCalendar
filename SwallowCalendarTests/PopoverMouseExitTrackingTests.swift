//
//  PopoverMouseExitTrackingTests.swift
//  SwallowCalendarTests
//
//  fix: status-popover-mouse-exit-no-close：
//  弹层内容视图原先无鼠标跟踪，弹窗展开后鼠标从弹窗移出（非经图标路径）
//  没有触发源，弹窗永不关闭。守门用例：弹层视图必须安装 owner 为 hover
//  控制器的 NSTrackingArea，复用 mouseExited → 延迟关闭检查链（与图标
//  移出同款 300ms 语义）。
//

import XCTest
import AppKit
@testable import SwallowCalendar

@MainActor
final class PopoverMouseExitTrackingTests: XCTestCase {

    /// 弹层内容视图必须安装鼠标跟踪区（fix: status-popover-mouse-exit-no-close）：
    /// 弹窗展开后鼠标从弹窗移出（非经图标路径）应同样触发延迟关闭检查
    func testPopoverViewHasMouseExitTracking() {
        let controller = StatusItemHoverController()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 460))
        controller.installPopoverTracking(on: view)

        let areas = view.trackingAreas.filter { $0.owner === controller }
        XCTAssertFalse(areas.isEmpty, "弹层内容视图缺少鼠标跟踪区（移出弹窗不会关闭弹窗）")

        guard let area = areas.first else { return }
        XCTAssertTrue(area.options.contains(.mouseEnteredAndExited), "跟踪区必须监听鼠标进入/移出事件")
        XCTAssertTrue(area.options.contains(.activeAlways), "弹窗非 key 窗口，必须 .activeAlways 才能收到跟踪")
    }

    /// 幂等：重复安装不叠加跟踪区（防止同一视图重复触发 mouseExited 链）
    func testPopoverTrackingInstallIsIdempotent() {
        let controller = StatusItemHoverController()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 460))
        controller.installPopoverTracking(on: view)
        controller.installPopoverTracking(on: view)

        let count = view.trackingAreas.filter { $0.owner === controller }.count
        XCTAssertEqual(count, 1, "重复安装应去重，不叠加跟踪区")
    }
}
