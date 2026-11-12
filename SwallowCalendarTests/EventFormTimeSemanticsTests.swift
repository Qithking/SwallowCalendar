//
//  EventFormTimeSemanticsTests.swift
//  SwallowCalendarTests
//
//  表单时间语义回归（2026-11-12 全天时间口径重写）
//  全天勾选后新增「起始时间/结束时间」控件（默认 09:00/23:00，必填），
//  保存时携带所选时分落库（isAllDay 仍为全天）；
//  存量全天事件编辑回填保留原值、缺省补默认。
//

import XCTest
@testable import SwallowCalendar

@MainActor
final class EventFormTimeSemanticsTests: XCTestCase {

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, minute: Int = 0, second: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return Calendar.current.date(from: components)!
    }

    // MARK: - 全天保存组装（起始/结束时分落到「日期行」当天）

    /// 默认时分（09:00/23:00）：start/end 均落在日期行当天
    func testAllDayOccurrenceAssemblesDefaultTimes() {
        let day = date(2026, 12, 1)
        let start = date(2026, 12, 1, hour: 9)
        let end = date(2026, 12, 1, hour: 23)
        let result = AllDayTimeRules.occurrence(day: day, startTime: start, endTime: end)
        XCTAssertEqual(result.start.timeIntervalSince1970, date(2026, 12, 1, hour: 9).timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(result.end.timeIntervalSince1970, date(2026, 12, 1, hour: 23).timeIntervalSince1970, accuracy: 0.001)
    }

    /// 自定义时分：组装跟随控件值；end 日期强制同 start 当天（end 控件改到次日时钳回当天）
    func testAllDayOccurrenceFollowsCustomTimesAndClampsEndToStartDay() {
        let day = date(2026, 10, 31)
        let startTime = date(2026, 10, 30, hour: 8, minute: 30)   // 时分有意带别的日期
        let endTime = date(2026, 11, 2, hour: 17, minute: 45)
        let result = AllDayTimeRules.occurrence(day: day, startTime: startTime, endTime: endTime)
        XCTAssertEqual(result.start.timeIntervalSince1970, date(2026, 10, 31, hour: 8, minute: 30).timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(result.end.timeIntervalSince1970, date(2026, 10, 31, hour: 17, minute: 45).timeIntervalSince1970, accuracy: 0.001)
    }

    // MARK: - 编辑面板全天初值回填（保留原值、缺省补默认）

    /// 存量全天事件：起始/结束保留原值（如 00:00、23:59:59）
    func testAllDayInitialTimesKeepOriginalValues() {
        let day = date(2026, 12, 1)
        let originalStart = date(2026, 12, 1)
        let originalEnd = date(2026, 12, 1, hour: 23, minute: 59, second: 59)
        let result = AllDayTimeRules.initialTimes(originalStart: originalStart, originalEnd: originalEnd, day: day)
        XCTAssertEqual(result.start.timeIntervalSince1970, originalStart.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(result.end.timeIntervalSince1970, originalEnd.timeIntervalSince1970, accuracy: 0.001)
    }

    /// 缺省补默认：无 startDate → 当天 00:00；无 endDate → 当天 23:59
    func testAllDayInitialTimesFallbackToDefaults() {
        let day = date(2026, 12, 1)
        let result = AllDayTimeRules.initialTimes(originalStart: nil, originalEnd: nil, day: day)
        XCTAssertEqual(result.start.timeIntervalSince1970, date(2026, 12, 1).timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(result.end.timeIntervalSince1970, date(2026, 12, 1, hour: 23, minute: 59).timeIntervalSince1970, accuracy: 0.001)
    }

    /// 部分缺省：有起始无结束 → 结束补默认当天 23:59
    func testAllDayInitialTimesFillsMissingEndOnly() {
        let day = date(2026, 12, 1)
        let originalStart = date(2026, 12, 1, hour: 6, minute: 30)
        let result = AllDayTimeRules.initialTimes(originalStart: originalStart, originalEnd: nil, day: day)
        XCTAssertEqual(result.start.timeIntervalSince1970, originalStart.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(result.end.timeIntervalSince1970, date(2026, 12, 1, hour: 23, minute: 59).timeIntervalSince1970, accuracy: 0.001)
    }

    /// 循环展开实例：时间类参数仍全部裁剪（BUG-06 语义不变）
    func testOccurrenceInstanceDropsTimeParams() {
        let occurrence = date(2026, 12, 1, hour: 9)
        let occID = CachedEvent.makeOccurrenceID(baseID: "rec-base", occurrence: occurrence)
        let params = EditEventSheet.sanitizedTimeParams(
            for: occID,
            startDate: occurrence,
            endDate: occurrence.addingTimeInterval(3600),
            isAllDay: false
        )
        XCTAssertNil(params.startDate)
        XCTAssertNil(params.endDate)
        XCTAssertNil(params.isAllDay)
    }
}
