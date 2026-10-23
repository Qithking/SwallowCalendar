//
//  TodayTodoSorterTests.swift
//  SwallowCalendarTests
//
//  hover 今天待办弹层：排序与今天判定纯函数测试（plan step 4）
//

import XCTest
@testable import SwallowCalendar

final class TodayTodoSorterTests: XCTestCase {

    private var calendar: Calendar!
    private var now: Date!

    override func setUp() {
        super.setUp()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar = cal
        // 固定"现在"：2026-10-23 12:00
        now = cal.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 12))
    }

    private func makeEvent(
        id: String,
        startDate: Date?,
        isCompleted: Bool = false,
        isAllDay: Bool = false
    ) -> CachedEvent {
        CachedEvent(
            eventID: id,
            title: "t-\(id)",
            startDate: startDate,
            endDate: nil,
            isAllDay: isAllDay,
            calendarID: "test",
            calendarTitle: "测试",
            calendarColorHex: "#000000",
            category: .user,
            // 补传完成态：此前 isCompleted 参数被遗漏，导致已完成分组断言失真
            isCompleted: isCompleted
        )
    }

    // MARK: - 排序规则

    /// AC-1：无时间未完成置顶，排在有时间未完成之前
    func testNoTimeIncompletePinnedTop() {
        let noTime = makeEvent(id: "a", startDate: nil)
        let timed = makeEvent(id: "b", startDate: calendar.date(byAdding: .hour, value: -1, to: now))
        let sorted = TodayTodoSorter.sort([timed, noTime], now: now, calendar: calendar)
        XCTAssertEqual(sorted.map(\.eventID), ["a", "b"])
    }

    /// AC-1：未完成按 startDate 升序
    func testIncompleteSortedByStartDateAsc() {
        let late = makeEvent(id: "late", startDate: now.addingTimeInterval(3600))
        let early = makeEvent(id: "early", startDate: now.addingTimeInterval(600))
        let sorted = TodayTodoSorter.sort([late, early], now: now, calendar: calendar)
        XCTAssertEqual(sorted.map(\.eventID), ["early", "late"])
    }

    /// AC-1：已完成置底（排在全部未完成之后）
    func testCompletedPinnedBottom() {
        let done = makeEvent(id: "done", startDate: now.addingTimeInterval(600), isCompleted: true)
        let todo = makeEvent(id: "todo", startDate: now.addingTimeInterval(7200))
        let sorted = TodayTodoSorter.sort([done, todo], now: now, calendar: calendar)
        XCTAssertEqual(sorted.map(\.eventID), ["todo", "done"])
    }

    /// AC-1：已完成组内按 startDate 升序
    func testCompletedGroupSortedByStartDateAsc() {
        let doneLate = makeEvent(id: "dLate", startDate: now.addingTimeInterval(7200), isCompleted: true)
        let doneEarly = makeEvent(id: "dEarly", startDate: now.addingTimeInterval(600), isCompleted: true)
        let sorted = TodayTodoSorter.sort([doneLate, doneEarly], now: now, calendar: calendar)
        XCTAssertEqual(sorted.map(\.eventID), ["dEarly", "dLate"])
    }

    /// AC-1：已完成无时间排在已完成组内最前（组内时间升序，nil 视为最早）
    func testCompletedNoTimeAtBottomGroupStart() {
        let doneNoTime = makeEvent(id: "dNone", startDate: nil, isCompleted: true)
        let doneTimed = makeEvent(id: "dTime", startDate: now.addingTimeInterval(600), isCompleted: true)
        let sorted = TodayTodoSorter.sort([doneTimed, doneNoTime], now: now, calendar: calendar)
        XCTAssertEqual(sorted.map(\.eventID), ["dNone", "dTime"])
    }

    /// AC-1：综合分组——无时间未完成 > 有时间未完成 > 已完成
    func testFullGroupOrdering() {
        let done = makeEvent(id: "done", startDate: now, isCompleted: true)
        let timed = makeEvent(id: "timed", startDate: now.addingTimeInterval(600))
        let noTime = makeEvent(id: "noTime", startDate: nil)
        let sorted = TodayTodoSorter.sort([done, timed, noTime], now: now, calendar: calendar)
        XCTAssertEqual(sorted.map(\.eventID), ["noTime", "timed", "done"])
    }

    /// 排序稳定性：同组同时间保持输入顺序
    func testSortStableForEqualKeys() {
        let a = makeEvent(id: "a", startDate: now)
        let b = makeEvent(id: "b", startDate: now)
        let sorted = TodayTodoSorter.sort([a, b], now: now, calendar: calendar)
        XCTAssertEqual(sorted.map(\.eventID), ["a", "b"])
    }

    // MARK: - 今天判定

    /// 无时间待办恒算今天（spec：随手记纯待办置顶显示）
    func testNilStartDateAlwaysIncluded() {
        XCTAssertTrue(TodayTodoSorter.isToday(nil, now: now, calendar: calendar))
    }

    /// 当天事项（含当天 00:00 的全天事项）算今天
    func testSameDayIncluded() {
        let todayStart = calendar.startOfDay(for: now)
        XCTAssertTrue(TodayTodoSorter.isToday(todayStart, now: now, calendar: calendar))
    }

    /// 昨天事项不算今天
    func testOtherDayExcluded() {
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        XCTAssertFalse(TodayTodoSorter.isToday(yesterday, now: now, calendar: calendar))
    }

    // MARK: - 超时判定（口径经用户确认：仅带时间且开始时间已过、未完成才算）

    /// 带时间未完成且开始时间已过 → 超时
    func testOverdueTimedPastStart() {
        let past = makeEvent(id: "a", startDate: now.addingTimeInterval(-3600))
        XCTAssertTrue(TodayTodoSorter.isOverdue(past, now: now))
    }

    /// 带时间未完成但开始时间未到 → 不超时
    func testNotOverdueFutureStart() {
        let future = makeEvent(id: "b", startDate: now.addingTimeInterval(3600))
        XCTAssertFalse(TodayTodoSorter.isOverdue(future, now: now))
    }

    /// 开始时间恰好等于当前时刻 → 不算超时（与主面板严格小于口径一致）
    func testNotOverdueExactlyNow() {
        let exact = makeEvent(id: "c", startDate: now)
        XCTAssertFalse(TodayTodoSorter.isOverdue(exact, now: now))
    }

    /// 已过期但已完成 → 不显示超时（完成态已置灰）
    func testNotOverdueCompleted() {
        let done = makeEvent(id: "d", startDate: now.addingTimeInterval(-3600), isCompleted: true)
        XCTAssertFalse(TodayTodoSorter.isOverdue(done, now: now))
    }

    /// 全天任务当天不算超时（全天 startDate 为当天零点，若按时间已过判定会全天标红，违反口径）
    func testNotOverdueAllDay() {
        let dayStart = calendar.startOfDay(for: now)
        let allDay = makeEvent(id: "e", startDate: dayStart, isAllDay: true)
        XCTAssertFalse(TodayTodoSorter.isOverdue(allDay, now: now))
    }

    /// 无时间任务无期限 → 永不超时
    func testNotOverdueNilStartDate() {
        let noTime = makeEvent(id: "f", startDate: nil)
        XCTAssertFalse(TodayTodoSorter.isOverdue(noTime, now: now))
    }
}
