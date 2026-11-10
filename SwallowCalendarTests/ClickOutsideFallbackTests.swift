//
//  ClickOutsideFallbackTests.swift
//  SwallowCalendarTests
//
//  fix: click-outside-activation-gap
//  app 激活失败（如 Xcode/LLDB 运行时 NSApp.activate 失败，取证日志
//  open done active=false isKey=false）时面板未成为 key 窗口，此状态下
//  点击桌面/其他应用不产生 resignKey（面板本非 key）也不产生 resignActive
//  （app 本就 inactive），双关闭链全部沉默 → 面板无法关闭。
//
//  兜底方案：open 时安装全局鼠标按下监听器（global monitor 仅在 app 非
//  active 时收到事件，恰好覆盖该盲区），点击点在面板外则关闭。
//  本测试覆盖判定逻辑与监听器生命周期接线。
//

import XCTest
import SwiftUI
@testable import SwallowCalendar

@MainActor
final class ClickOutsideFallbackTests: XCTestCase {

    private var panel: FloatingPanel<AnyView>!

    override func setUp() {
        super.setUp()
        panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 600),
            identifier: "TestClickOutsidePanel",
            statusBarButton: nil,
            onClose: {}
        ) {
            AnyView(Text("click-outside-test"))
        }
    }

    override func tearDown() {
        if panel.isPresented { panel.close() }
        panel = nil
        AppSettings.shared.isWindowPinned = false
        super.tearDown()
    }

    /// 点击点在面板外、已显示、未固定 → 应关闭（兜底链命中）
    func testGlobalClickOutsideFrameShouldClose() {
        panel.open()
        XCTAssertTrue(panel.isPresented)

        let outside = NSPoint(x: panel.frame.maxX + 100, y: panel.frame.maxY + 100)
        XCTAssertTrue(panel.shouldCloseOnGlobalClick(at: outside))
    }

    /// 点击点在面板内（如点击面板自身激活 app）→ 不应关闭
    func testGlobalClickInsideFrameShouldNotClose() {
        panel.open()
        XCTAssertTrue(panel.isPresented)

        let inside = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        XCTAssertFalse(panel.shouldCloseOnGlobalClick(at: inside))
    }

    /// 面板已固定（pin）→ 全局点击不应关闭
    func testGlobalClickPinnedShouldNotClose() {
        AppSettings.shared.isWindowPinned = true
        panel.open()
        XCTAssertTrue(panel.isPresented)

        let outside = NSPoint(x: panel.frame.maxX + 100, y: panel.frame.maxY + 100)
        XCTAssertFalse(panel.shouldCloseOnGlobalClick(at: outside))
    }

    /// 面板未显示 → 全局点击不应触发任何关闭逻辑
    func testGlobalClickNotPresentedShouldNotClose() {
        XCTAssertFalse(panel.isPresented)

        let outside = NSPoint(x: 9999, y: 9999)
        XCTAssertFalse(panel.shouldCloseOnGlobalClick(at: outside))
    }

    /// 生命周期接线：open 安装监听器，close 移除（防泄漏与重复触发）
    func testMonitorLifecycleFollowsPanelPresentation() {
        XCTAssertFalse(panel.hasGlobalClickMonitor, "面板未显示时不应持有全局监听器")

        panel.open()
        XCTAssertTrue(panel.hasGlobalClickMonitor, "open 后应安装全局监听器兜底")

        panel.close()
        XCTAssertFalse(panel.hasGlobalClickMonitor, "close 后应移除全局监听器")
    }

    /// R-1 同型竞态防回归：激活失败态（面板非 key、app 非 active）下点击状态栏
    /// 图标，global monitor 收到 mouseDown 兜底 close，随后 button action 的
    /// toggle 晚到——若 global close 不写回声时间戳，toggle 按 presented=false
    /// 走 open 分支重开面板（一轮点击关了又开 = 图标收不掉）。global close 必须
    /// 与 resignKey close 同样写入回声时间戳，让 toggle 在窗口期内识别并忽略
    func testGlobalClickCloseEchoBlocksToggleReopen() {
        panel.open()
        XCTAssertTrue(panel.isPresented)

        // global monitor 命中：面板外点击触发兜底关闭
        let outside = NSPoint(x: panel.frame.maxX + 100, y: panel.frame.maxY + 100)
        panel.closeOnGlobalClick(at: outside)
        XCTAssertFalse(panel.isPresented)

        // 随后 button action 到达：回声窗口内应被吞，不重开
        panel.toggle()
        XCTAssertFalse(panel.isPresented, "global close 后的 toggle 回声应被吞掉，不重开面板")
    }

    /// 回声窗口外护栏：global close 后超过窗口期的点击应正常打开，不被误吞
    func testToggleAfterGlobalClickEchoWindowOpensNormally() {
        panel.open()
        XCTAssertTrue(panel.isPresented)

        let outside = NSPoint(x: panel.frame.maxX + 100, y: panel.frame.maxY + 100)
        panel.closeOnGlobalClick(at: outside)
        XCTAssertFalse(panel.isPresented)

        Thread.sleep(forTimeInterval: PanelToggle.resignKeyEchoWindow + 0.05)
        panel.toggle()
        XCTAssertTrue(panel.isPresented, "回声窗口外的点击应正常打开面板")
    }
}
