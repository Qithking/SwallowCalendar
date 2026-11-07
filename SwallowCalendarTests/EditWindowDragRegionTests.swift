//
//  EditWindowDragRegionTests.swift
//  SwallowCalendarTests
//
//  回归测试（bug: edit-window-cancel-unresponsive）：
//  「修改事项」窗口的标题栏拖动区曾按非翻转坐标 y = 高度 - 28 摆放，而 contentView
//  （NSHostingView）是翻转坐标系 → 拖动区实际落到窗口底部 28pt，盖住底部操作行的
//  取消/保存按钮；拖动区又在 SwiftUI 内容之上，点击被 mouseDown 当成窗口拖动吞掉。
//  本测试锁定落位函数：翻转坐标系必须贴顶，且不得覆盖底部操作行。
//

import XCTest
import AppKit
@testable import SwallowCalendar

@MainActor
final class EditWindowDragRegionTests: XCTestCase {

    private let titlebar = EditEventWindowManager.titlebarHeight

    /// 翻转坐标系（NSHostingView 实际情形）：必须以 y=0 贴顶，弹性留白在底侧
    func testFlippedPlacementPinsToTop() {
        let bounds = NSRect(x: 0, y: 0, width: 340, height: 488)
        let placement = EditEventWindowManager.dragRegionPlacement(
            inBounds: bounds, isFlipped: true, leadingInset: 80
        )

        XCTAssertEqual(placement.frame.minY, 0, "翻转坐标系贴顶应为 y=0")
        XCTAssertEqual(placement.frame.maxY, titlebar, "拖动区高度不得越出标题栏")
        XCTAssertEqual(placement.frame.minX, 80, "左侧留空避开交通灯")
        XCTAssertEqual(placement.frame.width, 260, "右侧应铺满")
        XCTAssertTrue(placement.autoresizingMask.contains(.maxYMargin), "翻转坐标系贴顶需 .maxYMargin")
        XCTAssertFalse(placement.autoresizingMask.contains(.minYMargin), "翻转坐标系用 .minYMargin 会随高度下移")
    }

    /// 非翻转坐标系：贴顶为 y = 高度 - 28，弹性留白在底侧用 .minYMargin
    func testNonFlippedPlacementPinsToTop() {
        let bounds = NSRect(x: 0, y: 0, width: 340, height: 488)
        let placement = EditEventWindowManager.dragRegionPlacement(
            inBounds: bounds, isFlipped: false, leadingInset: 80
        )

        XCTAssertEqual(placement.frame.minY, 488 - titlebar)
        XCTAssertEqual(placement.frame.maxY, 488)
        XCTAssertTrue(placement.autoresizingMask.contains(.minYMargin))
        XCTAssertFalse(placement.autoresizingMask.contains(.maxYMargin))
    }

    /// 窗口高度增长（内容自适应）后拖动区仍贴顶，不落到底部操作行（按钮所在区域）
    func testFlippedRegionStaysOnTopAfterResize() {
        let superview = FlippedContainerView(frame: NSRect(x: 0, y: 0, width: 340, height: 488))
        let placement = EditEventWindowManager.dragRegionPlacement(
            inBounds: superview.bounds, isFlipped: true, leadingInset: 80
        )
        let region = TitlebarDragRegionView(frame: placement.frame)
        region.autoresizingMask = placement.autoresizingMask
        superview.addSubview(region)

        superview.setFrameSize(NSSize(width: 340, height: 600))

        XCTAssertEqual(region.frame.minY, 0, "窗口变高后拖动区必须仍在顶部")
        XCTAssertLessThanOrEqual(
            region.frame.maxY, titlebar,
            "拖动区不得覆盖底部「取消/保存」操作行"
        )
    }

    /// 内容区过窄时宽度收敛为 0，不得出现负宽（防御性边界）
    func testLeadingInsetClampedWhenNarrow() {
        let placement = EditEventWindowManager.dragRegionPlacement(
            inBounds: NSRect(x: 0, y: 0, width: 60, height: 200),
            isFlipped: true,
            leadingInset: 80
        )
        XCTAssertEqual(placement.frame.width, 0)
    }
}

/// 与 NSHostingView 一致的翻转坐标系容器，用于复现 autoresizing 行为
private final class FlippedContainerView: NSView {
    override var isFlipped: Bool { true }
}
