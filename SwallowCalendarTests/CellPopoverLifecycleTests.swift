//  CellPopoverLifecycleTests.swift
//  SwallowCalendarTests
//
//  弹窗生命周期：主界面收起时 hover 弹窗同步关闭
//  （bug: popover-leftover-after-main-panel-close——主面板 close 清空
//   contentViewController 销毁 SwiftUI 树，CellPopoverPresenter 缺拆除钩子
//   导致日历格子/事项行弹窗残留屏幕）
//

import XCTest
import SwiftUI
@testable import SwallowCalendar

@MainActor
final class CellPopoverLifecycleTests: XCTestCase {

    /// 主界面收起销毁 SwiftUI 视图树时，SwiftUI 拆除 representable 会调用
    /// dismantleUIView 钩子；钩子必须关闭 coordinator 持有的独立弹窗窗口
    func testDismantleClosesShowingPopover() throws {
        // 前置：模拟 hover 弹窗显示中（独立 NSWindow，orderFrontRegardless）
        let coordinator = CellPopoverWindowController()
        coordinator.show(
            content: { _, _ in Text("bug-repro") },
            anchorInScreen: NSRect(x: 100, y: 100, width: 20, height: 20),
            baseWindow: nil
        )
        XCTAssertTrue(coordinator.isShowing, "前置失败：弹窗应已显示")

        // 模拟主界面收起时的 representable 拆除（SwiftUI 调用点）
        CellPopoverPresenter<Color>.dismantleUIView(NSView(), coordinator: coordinator)

        // 弹窗必须随拆除关闭，否则主界面收起后屏幕残留
        XCTAssertFalse(coordinator.isShowing, "dismantle 后弹窗应已关闭，不应残留")
    }
}
