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
}
