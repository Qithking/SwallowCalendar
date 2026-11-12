//
//  PanelFilterModeClampTests.swift
//  SwallowCalendarTests
//
//  过滤档位持久化记忆回归测试（2026-11-12）：
//  应用设置「默认显示待办」已移除——主界面（五档含全部）、菜单栏 hover 弹层
//  （四档）、桌面面板（四档）三入口各自改档即持久化，启动加载上次选择；
//  无记忆（空串/脏数据）时按入口原默认初始化（主界面/弹层本月、面板今天）。
//

import XCTest
@testable import SwallowCalendar

@MainActor
final class PanelFilterModeClampTests: XCTestCase {

    // MARK: - 主界面过滤档（五档含「全部」）

    /// mainFilterMode didSet 写入 UserDefaults（round-trip）
    func testMainFilterModePersists() {
        AppSettings.shared.mainFilterMode = EventFilterMode.all.rawValue
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: "mainFilterMode"),
            EventFilterMode.all.rawValue
        )
        AppSettings.shared.mainFilterMode = ""
    }

    /// 存储值解析：五档合法值原样；空串/脏数据 → nil（视图回退本月）
    func testMainFilterModeEnumParses() {
        for mode in EventFilterMode.allCases {
            AppSettings.shared.mainFilterMode = mode.rawValue
            XCTAssertEqual(AppSettings.shared.mainFilterModeEnum, mode,
                           "主界面五档 \(mode.rawValue) 应原样保留")
        }
        AppSettings.shared.mainFilterMode = "garbage"
        XCTAssertNil(AppSettings.shared.mainFilterModeEnum, "脏数据应返回 nil")
        AppSettings.shared.mainFilterMode = ""
    }

    // MARK: - 弹层过滤档（四档，无「全部」）

    /// hoverFilterMode didSet 写入 UserDefaults（round-trip）
    func testHoverFilterModePersists() {
        AppSettings.shared.hoverFilterMode = EventFilterMode.thisWeek.rawValue
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: "hoverFilterMode"),
            EventFilterMode.thisWeek.rawValue
        )
        AppSettings.shared.hoverFilterMode = ""
    }

    /// 存储值解析：四档合法值原样；空串/「全部」档/脏数据 → nil（视图回退本月）
    func testHoverFilterModeEnumClampsToPanelModes() {
        for mode in DesktopTodoPanelFilter.modes {
            AppSettings.shared.hoverFilterMode = mode.rawValue
            XCTAssertEqual(AppSettings.shared.hoverFilterModeEnum, mode)
        }
        AppSettings.shared.hoverFilterMode = EventFilterMode.all.rawValue
        XCTAssertNil(AppSettings.shared.hoverFilterModeEnum, "「全部」档不属于弹层四档，应返回 nil")
        AppSettings.shared.hoverFilterMode = "garbage"
        XCTAssertNil(AppSettings.shared.hoverFilterModeEnum, "脏数据应返回 nil")
        AppSettings.shared.hoverFilterMode = ""
    }

    // MARK: - 弹层初始档（bug: popover-anchor 回归）

    /// NSPopover show 后 onAppear 切档会二次改变内容尺寸，macOS 26 弹层重排
    /// 时序不稳（实测弹层脱离锚点错位/高度不跟手）——初始档必须在弹层挂载前
    /// 由静态解析函数定死，视图 onAppear 只刷数据不再切档

    /// 弹层初始档解析：有记忆档取记忆档；无记忆/脏数据回退本月（弹层原初始档）
    func testPopoverInitialModeResolvedBeforeShow() {
        AppSettings.shared.hoverFilterMode = EventFilterMode.today.rawValue
        XCTAssertEqual(
            TodayTodoPopoverView.resolveInitialMode(from: AppSettings.shared),
            .today,
            "有记忆档应在挂载前解析为记忆档"
        )

        AppSettings.shared.hoverFilterMode = ""
        XCTAssertEqual(
            TodayTodoPopoverView.resolveInitialMode(from: AppSettings.shared),
            .thisMonth,
            "无记忆应回退本月（弹层原初始档）"
        )

        AppSettings.shared.hoverFilterMode = "garbage"
        XCTAssertEqual(
            TodayTodoPopoverView.resolveInitialMode(from: AppSettings.shared),
            .thisMonth,
            "脏数据应回退本月"
        )

        AppSettings.shared.hoverFilterMode = ""
    }

    // MARK: - 弹层固定高度（bug: popover-fixed-height 回归）

    /// NSPopover show 后 contentSize 变化 macOS 26 不重排（实测高度定格，
    /// 空态弹出后切档高度不涨）：内容区必须固定高度，与档位/数据量无关
    func testPopoverContentHeightIsFixed() {
        XCTAssertEqual(
            TodayTodoPopoverView.contentHeight, 420,
            "内容区固定高度应沿用原列表上限 420"
        )
        // bug: popover-initial-position 第4轮——show 前必须显式告知完整内容尺寸：
        // macOS 26 show 前不执行 SwiftUI 布局（contentSize={0,0}），系统按默认 320
        // 估算定位，内容渲染成 457 高后窗口原点不动 → 顶部冲出菜单栏
        XCTAssertEqual(
            TodayTodoPopoverView.contentWidth, 300,
            "弹层宽度常量应为 300"
        )
        XCTAssertEqual(
            TodayTodoPopoverView.showContentSize.width, TodayTodoPopoverView.contentWidth,
            "show 前告知的宽度应与视图宽度同源"
        )
        XCTAssertGreaterThan(
            TodayTodoPopoverView.showContentSize.height,
            TodayTodoPopoverView.contentHeight,
            "show 前告知的高度必须覆盖档位行 + 分割线 + 内容区"
        )
    }

    // MARK: - show 前尺寸解析（bug: popover-initial-position 第4轮）

    /// 实测尺寸有效时优先采用实测（宽度统一为视图宽度，高度取实测）
    func testResolvedContentSizeUsesMeasured() {
        let resolved = TodayTodoPopoverView.resolvedContentSize(
            measured: NSSize(width: 320, height: 457)
        )
        XCTAssertEqual(resolved.width, TodayTodoPopoverView.contentWidth,
                       "宽度应统一为视图宽度常量")
        XCTAssertEqual(resolved.height, 457, "高度应采用实测值")
    }

    /// 实测为 nil（视图尚未布局）→ 退回兜底尺寸
    func testResolvedContentSizeFallsBackWhenNil() {
        XCTAssertEqual(
            TodayTodoPopoverView.resolvedContentSize(measured: nil),
            TodayTodoPopoverView.showContentSize
        )
    }

    /// 实测为 0 值（布局未执行，异常值）→ 退回兜底尺寸，不采用 0
    func testResolvedContentSizeFallsBackWhenZero() {
        XCTAssertEqual(
            TodayTodoPopoverView.resolvedContentSize(measured: NSSize(width: 0, height: 0)),
            TodayTodoPopoverView.showContentSize
        )
    }

    // MARK: - 桌面面板过滤档（四档，沿用 todoPanelFilterMode）

    /// todoPanelFilterMode didSet 写入 UserDefaults（round-trip）
    func testPanelFilterModePersists() {
        AppSettings.shared.todoPanelFilterMode = EventFilterMode.thisWeek.rawValue
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: "todoPanelFilterMode"),
            EventFilterMode.thisWeek.rawValue
        )
        AppSettings.shared.todoPanelFilterMode = ""
    }

    /// 存储值解析：四档合法值 → 对应档位
    func testPanelFilterModeEnumParsesValidModes() {
        for mode in DesktopTodoPanelFilter.modes {
            AppSettings.shared.todoPanelFilterMode = mode.rawValue
            XCTAssertEqual(AppSettings.shared.todoPanelFilterModeEnum, mode)
        }
        AppSettings.shared.todoPanelFilterMode = ""
    }

    /// 存储值解析：空串（默认）/非法值（主界面「全部」档或脏数据）→ nil，调用方回退入口默认
    func testPanelFilterModeEnumReturnsNilForInvalidOrEmpty() {
        AppSettings.shared.todoPanelFilterMode = ""
        XCTAssertNil(AppSettings.shared.todoPanelFilterModeEnum, "空串应返回 nil（回退入口默认）")

        AppSettings.shared.todoPanelFilterMode = EventFilterMode.all.rawValue
        XCTAssertNil(AppSettings.shared.todoPanelFilterModeEnum, "「全部」档不属于面板四档，应返回 nil")

        AppSettings.shared.todoPanelFilterMode = "garbage"
        XCTAssertNil(AppSettings.shared.todoPanelFilterModeEnum, "脏数据应返回 nil")

        AppSettings.shared.todoPanelFilterMode = ""
    }
}
