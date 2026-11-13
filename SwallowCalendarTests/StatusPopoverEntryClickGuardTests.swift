//
//  StatusPopoverEntryClickGuardTests.swift
//  SwallowCalendarTests
//
//  fix: status-popover-entry-click-open-panel 守门用例：
//  用户需求——hover 弹层内点击条目文字不得触发「关弹层 + 打开主面板」，
//  该行为只允许由状态栏图标点击（performStatusItemClick）触发。
//  扫描源码，发现弹层视图/控制器重新挂上条目点击唤起手势或回调即失败。
//

import XCTest

final class StatusPopoverEntryClickGuardTests: XCTestCase {

    /// 仓库根目录（由测试文件位置推导）
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // SwallowCalendarTests
        .deletingLastPathComponent()   // 仓库根

    private func source(_ relativePath: String) -> String? {
        try? String(
            contentsOf: Self.repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    /// 弹层条目点击唤起主面板的手势与回调禁止复活
    func testPopoverViewHasNoEntryTapGesture() {
        guard let content = source("SwallowCalendar/Views/StatusItem/TodayTodoPopoverView.swift") else {
            return XCTFail("未找到 TodayTodoPopoverView.swift")
        }
        XCTAssertFalse(
            content.contains(".onTapGesture"),
            "弹层条目不得挂点击手势（点击文字唤起主面板已被用户需求禁止）"
        )
        XCTAssertFalse(
            content.contains("onOpenMainPanel"),
            "弹层视图不得保留 onOpenMainPanel 回调（条目点击唤起主面板链路已删除）"
        )
    }

    /// 弹层控制器不得保留条目点击唤起入口（仅图标点击可触发关弹层 + 开主面板）
    func testHoverControllerHasNoOpenMainPanelEntry() {
        guard let content = source("SwallowCalendar/Services/StatusItemHoverController.swift") else {
            return XCTFail("未找到 StatusItemHoverController.swift")
        }
        for forbidden in ["openMainPanel", "onOpenMainPanel"] {
            XCTAssertFalse(
                content.contains(forbidden),
                "StatusItemHoverController 不得保留 \(forbidden)（仅图标点击可触发）"
            )
        }
    }
}
