//
//  CountdownCapsuleWidthTests.swift
//  SwallowCalendarTests
//
//  回归测试（bug: countdown-capsule-jitter）：
//  倒计时胶囊字体必须为等宽数字变体——秒级刷新时同字符数文本宽度恒定，
//  否则比例数字（'1' 窄 '8' 宽）使胶囊宽度逐秒变化，推挤行内布局，
//  主界面/桌面面板/菜单弹层三处同显抖动（与徽标 badge-jitter-ugly 同型）
//

import XCTest
import SwiftUI
import AppKit
@testable import SwallowCalendar

final class CountdownCapsuleWidthTests: XCTestCase {

    /// 以胶囊字体渲染文本并测量宽度（NSHostingView.fittingSize 同步求值，无需窗口）
    private func capsuleTextWidth(_ text: String) -> CGFloat {
        NSHostingView(rootView: Text(text).font(CountdownFormatter.capsuleFont)).fittingSize.width
    }

    /// 同字符数、不同数字组合的 HH:mm:ss 宽度必须恒定（等宽数字根治每秒抖动）
    func testSameCharCountDigitsEqualWidth() {
        let widths = ["11:11:11", "18:18:18", "88:88:88"].map(capsuleTextWidth)
        XCTAssertEqual(widths[0], widths[1], accuracy: 0.1, "同字符数数字串宽度应恒定: \(widths)")
        XCTAssertEqual(widths[1], widths[2], accuracy: 0.1, "同字符数数字串宽度应恒定: \(widths)")
    }

    /// 跨天格式「N天HH:mm:ss」天位数字组合变化（1天→2天）同样不得改变宽度
    func testDayPrefixDigitsEqualWidth() {
        let w1 = capsuleTextWidth("1天08:56:43")
        let w2 = capsuleTextWidth("2天08:56:43")
        XCTAssertEqual(w1, w2, accuracy: 0.1, "跨天格式同字符数宽度应恒定: \(w1) vs \(w2)")
    }
}
