//
//  EventFormTimeSemanticsTests.swift
//  SwallowCalendarTests
//
//  表单时间语义回归（2026-11-08 重写）
//  历史版本 7 条用例针对「移除全天开关」的临时实现（newTaskTimeParams /
//  editedTimeParams / CalendarService.allDayEndDate），该实现已回退且相关 API 不存在；
//  现按当前实现重写：全天编辑未改日期保留原 endDate、改日期按原跨度平移，
//  非全天不套用全天结束规则。
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

    /// 全天结束时间的历史原值（含结束日 23:59:59）
    private func allDayEnd(_ day: Date) -> Date {
        day.addingTimeInterval(24 * 3600 - 1)
    }

    // MARK: - 全天编辑

    /// 未改日期：服务层收到 nil，保留原 endDate（不写成次日 00:00）
    func testAllDayEditWithoutDateChangeKeepsOriginalEnd() {
        let start = date(2026, 12, 1)
        let end = allDayEnd(start)
        XCTAssertNil(
            EditEventSheet.allDayEndDateOnEdit(
                eventIsAllDay: true, originalStart: start, originalEnd: end, newStart: start
            )
        )
    }

    /// 同一天内只改时分：仍视为日期未变，保留原 endDate
    func testAllDayEditSameDayTimeChangeStillKeepsOriginalEnd() {
        let start = date(2026, 12, 1)
        let end = allDayEnd(start)
        let newStart = date(2026, 12, 1, hour: 8, minute: 30)
        XCTAssertNil(
            EditEventSheet.allDayEndDateOnEdit(
                eventIsAllDay: true, originalStart: start, originalEnd: end, newStart: newStart
            )
        )
    }

    /// 改日期（跨月 10/31 → 11/1）：结束按原跨度平移
    func testAllDayEditWithDateShiftKeepsSpanAcrossMonth() {
        let start = date(2026, 10, 31)
        let end = allDayEnd(start)
        let newStart = date(2026, 11, 1)
        let result = EditEventSheet.allDayEndDateOnEdit(
            eventIsAllDay: true, originalStart: start, originalEnd: end, newStart: newStart
        )
        let expected = end.addingTimeInterval(24 * 3600)
        XCTAssertEqual(result?.timeIntervalSince1970 ?? 0, expected.timeIntervalSince1970, accuracy: 0.001)
    }

    /// 改日期（跨年 12/31 → 次年 1/1）：结束按原跨度平移
    func testAllDayEditWithDateShiftKeepsSpanAcrossYear() {
        let start = date(2026, 12, 31)
        let end = allDayEnd(start)
        let newStart = date(2027, 1, 1)
        let result = EditEventSheet.allDayEndDateOnEdit(
            eventIsAllDay: true, originalStart: start, originalEnd: end, newStart: newStart
        )
        let expected = end.addingTimeInterval(24 * 3600)
        XCTAssertEqual(result?.timeIntervalSince1970 ?? 0, expected.timeIntervalSince1970, accuracy: 0.001)
    }

    /// 连续多日全天（10/30–11/01）改到 11/02：跨度 3 天保持
    func testMultiDayAllDayEditKeepsOriginalSpan() {
        let start = date(2026, 10, 30)
        let end = allDayEnd(date(2026, 11, 1))
        let newStart = date(2026, 11, 2)
        let result = EditEventSheet.allDayEndDateOnEdit(
            eventIsAllDay: true, originalStart: start, originalEnd: end, newStart: newStart
        )
        let expected = end.addingTimeInterval(3 * 24 * 3600)
        XCTAssertEqual(result?.timeIntervalSince1970 ?? 0, expected.timeIntervalSince1970, accuracy: 0.001)
    }

    /// 原本不是全天：不套用全天结束规则，交服务层按转换语义处理
    func testTimedEventEditDoesNotUseAllDayEndRule() {
        let start = date(2026, 12, 1, hour: 9)
        let end = start.addingTimeInterval(3600)
        XCTAssertNil(
            EditEventSheet.allDayEndDateOnEdit(
                eventIsAllDay: false, originalStart: start, originalEnd: end, newStart: start
            )
        )
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
