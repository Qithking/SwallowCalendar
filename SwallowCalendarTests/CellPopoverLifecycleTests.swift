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

    /// 主面板窗口关闭（失活收起等所有收起路径都走 NSPanel close）时弹窗同步关闭。
    /// bug: 非正常鼠标移动（截图工具接管鼠标等）下 hover exited 事件丢失，
    /// 主面板随后因失活收起，但 SwiftUI 树销毁路径的 dismantle 不保证调用，
    /// 弹窗窗口残留且 ignoresMouseEvents 无法点击关闭——窗口侧必须自带联动
    func testBaseWindowCloseClosesPopover() throws {
        let baseWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        baseWindow.isReleasedWhenClosed = false
        baseWindow.orderFrontRegardless()

        let coordinator = CellPopoverWindowController()
        coordinator.show(
            content: { _, _ in Text("bug-repro") },
            anchorInScreen: NSRect(x: 100, y: 100, width: 20, height: 20),
            baseWindow: baseWindow
        )
        XCTAssertTrue(coordinator.isShowing, "前置失败：弹窗应已显示")

        // 模拟主面板收起：NSPanel/NSWindow close 发 willCloseNotification
        baseWindow.close()

        XCTAssertFalse(coordinator.isShowing, "主面板关闭时弹窗应同步关闭，不应残留")
    }

    // MARK: - 右缘箭头定位（bug: 右侧箭头坐标系翻转——AppKit y 向上 / SwiftUI shape y 向下）

    /// 右缘箭头 tip 必须是「锚点距弹窗顶部」的距离（shape 坐标 y 向下）。
    /// bug 场景：锚点靠屏幕顶部（菜单栏下首行日期格子），弹窗被屏顶钳制后，
    /// 误用「距底部」坐标会让箭头上下镜像错到弹窗中下部
    func testRightArrowTipMeasuresFromBubbleTop() {
        let contentHeight: CGFloat = 300

        // bug 场景：弹窗被屏幕顶部钳制（minY=596、maxY=896），锚点 midY=850 靠屏顶
        // 距顶 = 896 - 850 = 46；旧实现（距底 = 850 - 596 = 254）会错到镜像位置
        let clampedToTop = CellPopoverWindowController.rightArrowTip(
            anchorMidY: 850,
            popupFrame: NSRect(x: 0, y: 596, width: 220, height: contentHeight),
            contentHeight: contentHeight
        )
        XCTAssertEqual(clampedToTop, 46, accuracy: 0.5)

        // 弹窗垂直居中于锚点时两种坐标等价（bug 隐蔽的原因），锁定居中语义
        let centered = CellPopoverWindowController.rightArrowTip(
            anchorMidY: 500,
            popupFrame: NSRect(x: 0, y: 350, width: 220, height: contentHeight),
            contentHeight: contentHeight
        )
        XCTAssertEqual(centered, contentHeight / 2, accuracy: 0.5)

        // 锚点越过气泡边缘时钳制在气泡内（预留箭头半宽 + 2）
        let clampedLow = CellPopoverWindowController.rightArrowTip(
            anchorMidY: 899,
            popupFrame: NSRect(x: 0, y: 596, width: 220, height: contentHeight),
            contentHeight: contentHeight
        )
        XCTAssertEqual(clampedLow, PopoverBubbleShape.arrowHalfWidth + 2, accuracy: 0.5)
        let clampedHigh = CellPopoverWindowController.rightArrowTip(
            anchorMidY: 0,
            popupFrame: NSRect(x: 0, y: 596, width: 220, height: contentHeight),
            contentHeight: contentHeight
        )
        XCTAssertEqual(clampedHigh, contentHeight - PopoverBubbleShape.arrowHalfWidth - 2, accuracy: 0.5)
    }
}
