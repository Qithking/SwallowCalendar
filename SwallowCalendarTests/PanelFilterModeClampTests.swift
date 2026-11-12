//
//  PanelFilterModeClampTests.swift
//  SwallowCalendarTests
//
//  弹层/面板默认过滤档位回归测试
//  bug: status-views-filter-default——弹层仅今日语义无档位切换，面板初始档
//  硬编码 .today，均未使用应用设置「默认显示待办」；
//  期望：设置值映射到四档（面板/弹层不含「全部」档）——四档原样、
//  「全部」回退本月（与 AppSettings defaultFilterModeEnum fallback 一致）
//

import XCTest
@testable import SwallowCalendar

@MainActor
final class PanelFilterModeClampTests: XCTestCase {

    /// 四档原样保留（today/thisWeek/thisMonth/thisYear）
    func testClampKeepsPanelModes() {
        for mode in DesktopTodoPanelFilter.modes {
            XCTAssertEqual(DesktopTodoPanelFilter.defaultMode(from: mode), mode,
                           "四档 \(mode.rawValue) 应原样保留")
        }
    }

    /// 设置为「全部」（主界面独有档）时回退本月——弹层/面板无全部档
    func testClampAllFallsBackToThisMonth() {
        XCTAssertEqual(DesktopTodoPanelFilter.defaultMode(from: .all), .thisMonth,
                       "「全部」档应回退本月（与 AppSettings fallback 一致）")
    }

    // MARK: - 面板过滤档持久化（用户需求：改档即保存，下次启动加载上次选择，无记忆回退设置默认）

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

    /// 存储值解析：空串（默认）/非法值（主界面「全部」档或脏数据）→ nil，调用方回退设置默认
    func testPanelFilterModeEnumReturnsNilForInvalidOrEmpty() {
        AppSettings.shared.todoPanelFilterMode = ""
        XCTAssertNil(AppSettings.shared.todoPanelFilterModeEnum, "空串应返回 nil（回退设置默认）")

        AppSettings.shared.todoPanelFilterMode = EventFilterMode.all.rawValue
        XCTAssertNil(AppSettings.shared.todoPanelFilterModeEnum, "「全部」档不属于面板四档，应返回 nil")

        AppSettings.shared.todoPanelFilterMode = "garbage"
        XCTAssertNil(AppSettings.shared.todoPanelFilterModeEnum, "脏数据应返回 nil")

        AppSettings.shared.todoPanelFilterMode = ""
    }
}
