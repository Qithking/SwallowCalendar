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
