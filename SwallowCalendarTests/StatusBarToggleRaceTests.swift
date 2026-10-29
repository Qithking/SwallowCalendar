//
//  StatusBarToggleRaceTests.swift
//  SwallowCalendarTests
//
//  fix: statusbar-toggle-race
//  主面板开着时再次点击状态栏图标，偶发「关不掉」：
//  点击 NSStatusBarButton 会使 key 面板先失 key（状态栏窗口不可 key，
//  NSApp.keyWindow 为 nil，windowDidResignKey 的 V-3 应用内窗口排除不命中）
//  → resignKey 先触发 close()，随后 button action 的 toggle() 又 open()
//  → 一轮点击经历「关了又开」，用户视角 = 无法关闭。
//
//  本测试在单测中显式构造该时序（resignKey 先到、action 后到），
//  断言一轮完整点击后面板最终应处于关闭态。
//

import XCTest
import SwiftUI
@testable import SwallowCalendar

@MainActor
final class StatusBarToggleRaceTests: XCTestCase {

    private var panel: FloatingPanel<AnyView>!

    override func setUp() {
        super.setUp()
        panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 600),
            identifier: "TestToggleRacePanel",
            statusBarButton: nil,
            onClose: {}
        ) {
            AnyView(Text("toggle-race-test"))
        }
    }

    override func tearDown() {
        if panel.isPresented { panel.close() }
        panel = nil
        AppSettings.shared.isWindowPinned = false
        super.tearDown()
    }

    /// 时序 B（竞态）：面板已开 → resignKey 先到 → action 的 toggle 后到。
    /// 用户期望：一轮点击后面板保持关闭。
    func testResignKeyBeforeToggleClickClosesPanel() {
        panel.open()
        XCTAssertTrue(panel.isPresented)

        // 1) 点击状态栏图标导致面板失 key：keyWindow 为 nil，V-3 排除不命中
        panel.windowDidResignKey(
            Notification(name: NSWindow.didResignKeyNotification, object: panel)
        )
        // 2) 随后 button action 到达，toggle 按「当前未显示」处理
        panel.toggle()

        XCTAssertFalse(panel.isPresented, "resignKey + toggle 一轮点击后面板应保持关闭")
    }

    /// 时序 A（正常路径护栏）：action 先到（toggle→close），resignKey 后到不应再有任何副作用
    func testToggleBeforeResignKeyStaysClosed() {
        panel.open()
        XCTAssertTrue(panel.isPresented)

        // 1) action 先到：正常关闭
        panel.toggle()
        XCTAssertFalse(panel.isPresented)

        // 2) resignKey 后到：面板已关，不应重开或异常
        panel.windowDidResignKey(
            Notification(name: NSWindow.didResignKeyNotification, object: panel)
        )
        XCTAssertFalse(panel.isPresented)
    }

    /// 回声窗口外护栏：resignKey 关闭后超过窗口期的点击应正常打开，不被误吞
    func testToggleAfterEchoWindowOpensNormally() {
        panel.open()
        XCTAssertTrue(panel.isPresented)

        // 失 key 关闭（写入回声时间戳）
        panel.windowDidResignKey(
            Notification(name: NSWindow.didResignKeyNotification, object: panel)
        )
        XCTAssertFalse(panel.isPresented)

        // 超过回声窗口后用户再点击：合法打开必须生效
        Thread.sleep(forTimeInterval: PanelToggle.resignKeyEchoWindow + 0.05)
        panel.toggle()
        XCTAssertTrue(panel.isPresented, "回声窗口外的点击应正常打开面板")
    }
}
