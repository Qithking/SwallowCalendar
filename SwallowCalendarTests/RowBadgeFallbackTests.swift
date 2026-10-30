//
//  RowBadgeFallbackTests.swift
//  SwallowCalendarTests
//
//  bug: completed-row-overdue-capsule（A-7）——已办历史行 startDate 在过去，
//  CountdownTextView 无完成态信息会在内部归零渲染「已过期」胶囊，行级须提前分流
//  bug: badge-fallback-redraw-every-second（A-6）——徽标开启且无待办时，
//  solid/stroke 样式 shouldCache=false，回退默认图标路径每秒 tick 全量重渲染
//

import XCTest
@testable import SwallowCalendar

final class RowBadgeFallbackTests: XCTestCase {

    // MARK: A-7 已办行时间徽标分流

    // V-1: 已完成历史行不渲染任何时间徽标（倒计时/已过期），未完成行维持原语义
    @MainActor
    func testCompletedRowShowsNoTimeBadge() {
        XCTAssertFalse(EventItemRow.showsTimeBadge(isCompleted: true, isOverdue: false),
                       "已完成行不得渲染倒计时/过期标识")
        XCTAssertFalse(EventItemRow.showsTimeBadge(isCompleted: true, isOverdue: true),
                       "已完成行即使时刻已过也不得渲染过期标识（对齐桌面面板语义）")
        XCTAssertTrue(EventItemRow.showsTimeBadge(isCompleted: false, isOverdue: false),
                      "未完成行照常渲染倒计时胶囊")
        XCTAssertTrue(EventItemRow.showsTimeBadge(isCompleted: false, isOverdue: true),
                      "未完成过期行照常渲染红字已过期")
    }

    // MARK: A-6 徽标回退图标重绘节流

    // V-2: 回退路径仅在「从徽标切回」或「样式/颜色 key 变化」时重绘
    func testFallbackRedrawThrottle() {
        // 首次回退：必须重绘
        XCTAssertTrue(StatusBarIconManager.needsFallbackRedraw(lastWasFallback: false, lastKey: nil, currentKey: "k1"))
        // 无待办期间每秒 tick：同 key 不重绘
        XCTAssertFalse(StatusBarIconManager.needsFallbackRedraw(lastWasFallback: true, lastKey: "k1", currentKey: "k1"))
        // 样式/颜色变更：重绘
        XCTAssertTrue(StatusBarIconManager.needsFallbackRedraw(lastWasFallback: true, lastKey: "k1", currentKey: "k2"))
        // 从倒计时徽标切回无事项：重绘
        XCTAssertTrue(StatusBarIconManager.needsFallbackRedraw(lastWasFallback: false, lastKey: "k1", currentKey: "k1"))
    }
}
