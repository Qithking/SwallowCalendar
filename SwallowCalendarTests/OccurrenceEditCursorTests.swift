//
//  OccurrenceEditCursorTests.swift
//  SwallowCalendarTests
//
//  BUG-06 回归：编辑循环展开出的单期行时，表单不得把时间参数传给 updateEvent；
//  否则会写回 EK base 并回拨整条序列游标（该期之后重新出现/历史错乱）。
//  测试宿主无 EK 授权，故覆盖「参数裁剪」这一触发条件本身。
//

import XCTest
@testable import SwallowCalendar

@MainActor
final class OccurrenceEditCursorTests: XCTestCase {

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 9) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return Calendar.current.date(from: components)!
    }

    /// 展开实例（复合 ID）：时间类参数必须全部裁剪为 nil
    func testOccurrenceInstanceDropsAllTimeParams() {
        let d0 = date(2026, 10, 26)
        let occID = CachedEvent.makeOccurrenceID(baseID: "rec-base", occurrence: d0)

        let params = EditEventSheet.sanitizedTimeParams(
            for: occID,
            startDate: d0,
            endDate: d0.addingTimeInterval(3600),
            isAllDay: false
        )

        XCTAssertNil(params.startDate)
        XCTAssertNil(params.endDate)
        XCTAssertNil(params.isAllDay)
    }

    /// 对照：非循环本体行（普通 ID）时间参数原样透传
    func testBaseEventKeepsTimeParams() {
        let d0 = date(2026, 10, 26)

        let params = EditEventSheet.sanitizedTimeParams(
            for: "single-base",
            startDate: d0,
            endDate: d0.addingTimeInterval(3600),
            isAllDay: false
        )

        XCTAssertEqual(params.startDate?.timeIntervalSince1970 ?? 0, d0.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(params.endDate?.timeIntervalSince1970 ?? 0, d0.addingTimeInterval(3600).timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(params.isAllDay, false)
    }

    // MARK: - 编辑全天事件：未改日期保留原结束时间

    /// 不改日期：返回 nil（服务层保留原 endDate，不写成次日 00:00）
    func testAllDayEditWithoutDateChangeKeepsOriginalEnd() {
        let start = date(2026, 10, 26, 0)
        let end = date(2026, 10, 26, 23).addingTimeInterval(59 * 60 + 59)
        XCTAssertNil(
            EditEventSheet.allDayEndDateOnEdit(
                eventIsAllDay: true, originalStart: start, originalEnd: end, newStart: start
            )
        )
    }

    /// 改日期：按原跨度平移（跨月 10/31 → 11/1）
    func testAllDayEditWithDateChangeShiftsEndAcrossMonth() {
        let start = date(2026, 10, 31, 0)
        let end = date(2026, 10, 31, 23).addingTimeInterval(59 * 60 + 59)
        let newStart = date(2026, 11, 1, 0)
        let result = EditEventSheet.allDayEndDateOnEdit(
            eventIsAllDay: true, originalStart: start, originalEnd: end, newStart: newStart
        )
        let expected = Calendar.current.date(byAdding: .day, value: 1, to: end)
        XCTAssertEqual(result?.timeIntervalSince1970 ?? 0, expected?.timeIntervalSince1970 ?? 0, accuracy: 0.001)
        let comps = Calendar.current.dateComponents([.month, .day], from: result ?? end)
        XCTAssertEqual(comps.month, 11)
    }

    /// 连续多日全天改日期：跨度保持（10/30–11/01 → 11/02–11/04）
    func testAllDayMultiDayEditKeepsSpan() {
        let start = date(2026, 10, 30, 0)
        let end = date(2026, 11, 1, 23).addingTimeInterval(59 * 60 + 59)
        let newStart = date(2026, 11, 2, 0)
        let result = EditEventSheet.allDayEndDateOnEdit(
            eventIsAllDay: true, originalStart: start, originalEnd: end, newStart: newStart
        )
        let expected = Calendar.current.date(byAdding: .day, value: 3, to: end)
        XCTAssertEqual(result?.timeIntervalSince1970 ?? 0, expected?.timeIntervalSince1970 ?? 0, accuracy: 0.001)
    }

    /// 原本不是全天：不回传 endDate，由服务层按单日处理
    func testTimedToAllDayEditDoesNotComputeEnd() {
        let start = date(2026, 10, 26, 9)
        let end = start.addingTimeInterval(3600)
        XCTAssertNil(
            EditEventSheet.allDayEndDateOnEdit(
                eventIsAllDay: false, originalStart: start, originalEnd: end, newStart: start
            )
        )
    }
}
