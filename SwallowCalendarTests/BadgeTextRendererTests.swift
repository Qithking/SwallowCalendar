//
//  BadgeTextRendererTests.swift
//  SwallowCalendarTests
//
//  badge-realtime-countdown B4 回归测试：徽标文本渲染
//  11pt 与日期图标视觉一致（修复 13pt 偏大）、字形级垂直居中、宽度自适应
//  bug-badge-jitter-ugly 回归：等宽数字防抖动、18pt 画布、无背景样式 template 化
//

import XCTest
@testable import SwallowCalendar

final class BadgeTextRendererTests: XCTestCase {

    // MARK: - 字号（11pt 等宽数字对齐日期图标）

    func testFontSolidIsBold11pt() {
        XCTAssertEqual(BadgeTextRenderer.font(for: .solid), NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold))
    }

    func testFontNoneIsRegular11pt() {
        XCTAssertEqual(BadgeTextRenderer.font(for: .none), NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular))
    }

    // MARK: - 等宽数字防抖动（bug-badge-jitter-ugly：同字符数不同数字组合宽度恒定）

    func testMonospacedDigitsEqualWidth() {
        let a = BadgeTextRenderer.render("11:11:11", style: .none, iconColor: .systemBlue)
        let b = BadgeTextRenderer.render("08:08:08", style: .none, iconColor: .systemBlue)
        XCTAssertEqual(a.size.width, b.size.width, "同字符数倒计时宽度必须一致，否则菜单栏图标每秒抖动")
    }

    func testMonospacedDigitsEqualWidthCJKMix() {
        let a = BadgeTextRenderer.render("1天08:56:43", style: .none, iconColor: .systemBlue)
        let b = BadgeTextRenderer.render("2天08:56:43", style: .none, iconColor: .systemBlue)
        XCTAssertEqual(a.size.width, b.size.width, "N天HH:mm:ss 格式天数变化不应影响宽度")
    }

    // MARK: - 画布尺寸（18pt 与日期图标统一；无背景样式 template 化）

    func testShortTextUsesMinWidth() {
        let image = BadgeTextRenderer.render("23", style: .none, iconColor: .systemBlue)
        XCTAssertEqual(image.size.height, 18)
        XCTAssertEqual(image.size.width, 22)
        XCTAssertTrue(image.isTemplate, "无背景纯文字应为 template，系统自动适配深浅菜单栏")
    }

    func testLongTextWidthAdapts() {
        let text = "29天08:56:43"
        let textSize = (text as NSString).size(withAttributes: [.font: BadgeTextRenderer.font(for: .none)])
        let image = BadgeTextRenderer.render(text, style: .none, iconColor: .systemBlue)
        XCTAssertEqual(image.size.height, 18)
        XCTAssertEqual(image.size.width, max(22, ceil(textSize.width) + 8))
    }

    func testSolidStyleKeepsColorInfo() {
        let image = BadgeTextRenderer.render("08:56:43", style: .solid, iconColor: .systemBlue)
        XCTAssertFalse(image.isTemplate, "实心背景需保留主题色，不走 template")
    }

    // MARK: - 字形级垂直居中（像素探针：ink 中线偏差 ≤0.5pt）

    func assertVerticallyCentered(text: String, style: AppSettings.CustomFormatStyle, isInk: (NSColor) -> Bool) throws {
        let image = BadgeTextRenderer.render(text, style: style, iconColor: .systemBlue)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
            return XCTFail("无法获取位图")
        }
        var top: Int?
        var bottom: Int?
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                if let c = rep.colorAt(x: x, y: y), isInk(c) {
                    if top == nil { top = y }
                    bottom = y
                    break
                }
            }
        }
        guard let t = top, let b = bottom else { return XCTFail("未检出文字墨迹") }
        let scale = Double(rep.pixelsHigh) / Double(image.size.height)
        let inkMid = (Double(t) + Double(b)) / 2
        let deviationPt = abs(inkMid - Double(rep.pixelsHigh) / 2) / scale
        XCTAssertLessThanOrEqual(deviationPt, 0.5, "\(text) ink 中线偏差 \(deviationPt)pt")
    }

    func testVerticalCenteringPlainDigits() throws {
        try assertVerticallyCentered(text: "23", style: .none) { $0.alphaComponent > 0.5 }
    }

    func testVerticalCenteringTimeText() throws {
        try assertVerticallyCentered(text: "08:56:43", style: .none) { $0.alphaComponent > 0.5 }
    }

    func testVerticalCenteringCJKMix() throws {
        try assertVerticallyCentered(text: "29天08:56:43", style: .none) { $0.alphaComponent > 0.5 }
    }

    func testVerticalCenteringSolidWhiteOnBlue() throws {
        try assertVerticallyCentered(text: "08:56:43", style: .solid) {
            $0.alphaComponent > 0.5 && $0.redComponent > 0.8 && $0.greenComponent > 0.8 && $0.blueComponent > 0.8
        }
    }
}
