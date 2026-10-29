//  RowActionHoverResetTests.swift
//  SwallowCalendarTests
//
//  行内操作后 hover 弹窗必须收起
//  （bug: popover-leftover-on-row-complete——重复任务完成后事件本体保留
//   （startDate 推进式序列），行不移除、dismantle 兜底不存在；鼠标仍悬停
//   行内时 onHover(false) 不触发，视图更新期间移出事件偶发丢失 →
//   isHovered 卡 true，弹窗悬空且无关闭者）
//

import XCTest
import SwiftUI
@testable import SwallowCalendar

@MainActor
final class RowActionHoverResetTests: XCTestCase {

    /// 行内操作（完成/取消完成/编辑/删除）必须先复位 hover 再执行动作：
    /// 复位驱动 CellPopoverPresenter.updateNSView(false) → coordinator.close()，
    /// 弹窗随操作立即收起，不再依赖 onHover(false) 或行移除 dismantle 兜底
    func testRowActionResetsHoverBeforeRunningAction() {
        // 前置：模拟鼠标悬停行内（弹窗显示中）
        var hovered = true
        let isHovered = Binding(get: { hovered }, set: { hovered = $0 })
        var ran = false

        // 模拟行内按钮点击（行内操作统一入口）
        EventItemRow.performRowAction(isHovered: isHovered) { ran = true }

        // hover 必须复位，否则弹窗残留屏幕
        XCTAssertFalse(hovered, "行内操作必须复位 hover，否则弹窗残留（悬停时 onHover(false) 不触发）")
        // 原动作必须照常执行
        XCTAssertTrue(ran, "复位后原操作必须照常执行")
    }
}
