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
}
