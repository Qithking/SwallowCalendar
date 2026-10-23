//
//  DesktopTodoPanelFilterTests.swift
//  SwallowCalendarTests
//
//  桌面待办面板：四档筛选纯函数测试（plan step 6+7）
//  注意：EventFilterMode.dateRange(from:) 内部使用 Calendar.current（系统时区）
//  与 AppSettings.shared.weekdayStart，故周档用例显式设置周起始日并恢复
//

import XCTest
@testable import SwallowCalendar

final class DesktopTodoPanelFilterTests: XCTestCase {

    private var calendar: Calendar!
    private var now: Date!

    override func setUp() {
        super.setUp()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar = cal
        // 固定"现在"：2026-10-23 12:00（周五）
        now = cal.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 12))
    }

    override func tearDown() {
        // 恢复默认周起始日（周一），避免污染其它用例与用户设置
        AppSettings.shared.weekdayStart = 2
        super.tearDown()
    }

    private func makeEvent(
        id: String,
        startDate: Date?,
        isCompleted: Bool = false,
        category: EventCategory = .user
    ) -> CachedEvent {
        CachedEvent(
            eventID: id,
            title: "t-\(id)",
            startDate: startDate,
            endDate: nil,
            isAllDay: false,
            calendarID: "test",
            calendarTitle: "测试",
            calendarColorHex: "#000000",
            category: category,
            isCompleted: isCompleted
        )
    }

    // MARK: - 无日期恒显（spec：随手记纯待办无到期语义，四档均显示）

    func testNilStartDateIncludedInAllFourModes() {
        let event = makeEvent(id: "none", startDate: nil)
        for mode in DesktopTodoPanelFilter.modes {
            XCTAssertTrue(
                DesktopTodoPanelFilter.included(event, mode: mode, now: now),
                "无日期待办应在 \(mode.rawValue) 档恒显示"
            )
        }
    }

    // MARK: - 今天档

    func testTodayIncludesTimedEventToday() {
        let event = makeEvent(id: "a", startDate: now)
        XCTAssertTrue(DesktopTodoPanelFilter.included(event, mode: .today, now: now))
    }

    func testTodayExcludesYesterdayAndTomorrow() {
        let yesterday = makeEvent(id: "y", startDate: calendar.date(byAdding: .day, value: -1, to: now))
        let tomorrow = makeEvent(id: "t", startDate: calendar.date(byAdding: .day, value: 1, to: now))
        XCTAssertFalse(DesktopTodoPanelFilter.included(yesterday, mode: .today, now: now))
        XCTAssertFalse(DesktopTodoPanelFilter.included(tomorrow, mode: .today, now: now))
    }

    /// 左闭右开：当天零点含、次日零点不含
    func testTodayBoundaryHalfOpen() {
        let dayStart = calendar.startOfDay(for: now)
        let nextDayStart = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        XCTAssertTrue(DesktopTodoPanelFilter.included(makeEvent(id: "s", startDate: dayStart), mode: .today, now: now))
        XCTAssertFalse(DesktopTodoPanelFilter.included(makeEvent(id: "e", startDate: nextDayStart), mode: .today, now: now))
    }

    // MARK: - 本周档（周起始日影响边界）

    /// 周一起始：2026-10-23 为周五，本周为 10-19（一）～ 10-25（日）
    func testThisWeekMondayStart() {
        AppSettings.shared.weekdayStart = 2
        let monday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 8))!
        let sunday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 8))!
        let nextMonday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 8))!
        XCTAssertTrue(DesktopTodoPanelFilter.included(makeEvent(id: "mon", startDate: monday), mode: .thisWeek, now: now))
        XCTAssertTrue(DesktopTodoPanelFilter.included(makeEvent(id: "sun", startDate: sunday), mode: .thisWeek, now: now))
        XCTAssertFalse(DesktopTodoPanelFilter.included(makeEvent(id: "next", startDate: nextMonday), mode: .thisWeek, now: now))
    }

    /// 周日起始：本周为 10-18（日）～ 10-24（六），周五 10-23 仍在本周内
    func testThisWeekSundayStart() {
        AppSettings.shared.weekdayStart = 1
        let sunday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 8))!
        let saturday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 8))!
        let nextSunday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 8))!
        XCTAssertTrue(DesktopTodoPanelFilter.included(makeEvent(id: "sun", startDate: sunday), mode: .thisWeek, now: now))
        XCTAssertTrue(DesktopTodoPanelFilter.included(makeEvent(id: "sat", startDate: saturday), mode: .thisWeek, now: now))
        XCTAssertFalse(DesktopTodoPanelFilter.included(makeEvent(id: "next", startDate: nextSunday), mode: .thisWeek, now: now))
    }

    // MARK: - 本月档

    func testThisMonthBoundaries() {
        let monthEnd = calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 8))!
        let nextMonth = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 8))!
        let lastMonth = calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 8))!
        XCTAssertTrue(DesktopTodoPanelFilter.included(makeEvent(id: "in", startDate: monthEnd), mode: .thisMonth, now: now))
        XCTAssertFalse(DesktopTodoPanelFilter.included(makeEvent(id: "next", startDate: nextMonth), mode: .thisMonth, now: now))
        XCTAssertFalse(DesktopTodoPanelFilter.included(makeEvent(id: "prev", startDate: lastMonth), mode: .thisMonth, now: now))
    }

    // MARK: - 本年档

    func testThisYearBoundaries() {
        let yearStart = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 8))!
        let yearEnd = calendar.date(from: DateComponents(year: 2026, month: 12, day: 31, hour: 8))!
        let nextYear = calendar.date(from: DateComponents(year: 2027, month: 1, day: 1, hour: 8))!
        let lastYear = calendar.date(from: DateComponents(year: 2025, month: 12, day: 31, hour: 8))!
        XCTAssertTrue(DesktopTodoPanelFilter.included(makeEvent(id: "in1", startDate: yearStart), mode: .thisYear, now: now))
        XCTAssertTrue(DesktopTodoPanelFilter.included(makeEvent(id: "in2", startDate: yearEnd), mode: .thisYear, now: now))
        XCTAssertFalse(DesktopTodoPanelFilter.included(makeEvent(id: "next", startDate: nextYear), mode: .thisYear, now: now))
        XCTAssertFalse(DesktopTodoPanelFilter.included(makeEvent(id: "prev", startDate: lastYear), mode: .thisYear, now: now))
    }

    // MARK: - 完成态与分类过滤（八轮需求：数据范围 = 仅用户待办）

    /// 已完成事项保留显示（面板负责置灰置底，不由筛选剔除）
    func testCompletedEventIncluded() {
        let done = makeEvent(id: "done", startDate: now, isCompleted: true)
        XCTAssertTrue(DesktopTodoPanelFilter.included(done, mode: .today, now: now))
    }

    /// 系统分类排除（八轮需求：霜降等节气/节假日来自系统日历，面板仅显示用户待办）
    func testSystemCategoryExcluded() {
        let system = makeEvent(id: "sys", startDate: now, category: .system)
        XCTAssertFalse(DesktopTodoPanelFilter.included(system, mode: .today, now: now))
    }

    /// 订阅分类排除（八轮用户确认：仅用户待办，与弹层/状态栏/提醒服务口径一致）
    func testSubscriptionCategoryExcluded() {
        let sub = makeEvent(id: "sub", startDate: now, category: .subscription)
        XCTAssertFalse(DesktopTodoPanelFilter.included(sub, mode: .today, now: now))
    }

    // MARK: - 时间显示格式（用户需求：非今天日期要显示全，看得明白）

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    /// 今天：保持紧凑时刻显示
    func testTimeTextToday() {
        XCTAssertEqual(
            DesktopTodoPanelTimeText.text(for: date(2026, 10, 23, 9, 5), isAllDay: false, now: now, calendar: calendar),
            "09:05"
        )
        XCTAssertEqual(
            DesktopTodoPanelTimeText.text(for: date(2026, 10, 23), isAllDay: true, now: now, calendar: calendar),
            "全天"
        )
    }

    /// 同年非今天：带月日
    func testTimeTextSameYearOtherDay() {
        XCTAssertEqual(
            DesktopTodoPanelTimeText.text(for: date(2026, 10, 25, 9, 5), isAllDay: false, now: now, calendar: calendar),
            "10月25日 09:05"
        )
        XCTAssertEqual(
            DesktopTodoPanelTimeText.text(for: date(2026, 10, 25), isAllDay: true, now: now, calendar: calendar),
            "10月25日 全天"
        )
    }

    /// 跨年：带年份
    func testTimeTextDifferentYear() {
        XCTAssertEqual(
            DesktopTodoPanelTimeText.text(for: date(2027, 1, 2, 9, 5), isAllDay: false, now: now, calendar: calendar),
            "2027年1月2日 09:05"
        )
        XCTAssertEqual(
            DesktopTodoPanelTimeText.text(for: date(2025, 12, 31), isAllDay: true, now: now, calendar: calendar),
            "2025年12月31日 全天"
        )
    }

    // MARK: - 状态筛选（用户需求：全部/待办（默认）/已办）

    func testStatusFilterTodoExcludesCompleted() {
        XCTAssertTrue(DesktopTodoPanelStatusFilter.todo.includes(isCompleted: false))
        XCTAssertFalse(DesktopTodoPanelStatusFilter.todo.includes(isCompleted: true), "待办档不应收录已完成")
    }

    func testStatusFilterDoneOnlyCompleted() {
        XCTAssertTrue(DesktopTodoPanelStatusFilter.done.includes(isCompleted: true))
        XCTAssertFalse(DesktopTodoPanelStatusFilter.done.includes(isCompleted: false), "已办档不应收录未完成")
    }

    func testStatusFilterAllIncludesBoth() {
        XCTAssertTrue(DesktopTodoPanelStatusFilter.all.includes(isCompleted: false))
        XCTAssertTrue(DesktopTodoPanelStatusFilter.all.includes(isCompleted: true))
    }

    /// 选项顺序锁定（视图下拉展示顺序：全部→待办→已办，待办为默认档）
    func testStatusFilterCaseOrder() {
        XCTAssertEqual(DesktopTodoPanelStatusFilter.allCases, [.all, .todo, .done])
    }

    // MARK: - 面板排序（用户需求：无到期日期排最前，其余按时间升序）

    func testPanelSortNoDateFirstThenAscending() {
        let early = makeEvent(id: "early", startDate: date(2026, 10, 23, 8))
        let late = makeEvent(id: "late", startDate: date(2026, 10, 25, 20))
        let noDate = makeEvent(id: "none", startDate: nil)
        let sorted = DesktopTodoPanelSort.sort([early, noDate, late])
        XCTAssertEqual(
            sorted.map(\.eventID),
            ["none", "early", "late"],
            "无日期最前，其余按开始时间从早到晚（升序，七轮需求）"
        )
    }

    func testPanelSortCompletedAtBottom() {
        let doneLater = makeEvent(id: "doneLater", startDate: date(2026, 10, 30), isCompleted: true)
        let todoEarly = makeEvent(id: "todoEarly", startDate: date(2026, 10, 23, 8))
        let sorted = DesktopTodoPanelSort.sort([doneLater, todoEarly])
        XCTAssertEqual(
            sorted.map(\.eventID),
            ["todoEarly", "doneLater"],
            "已完成置底（保留原口径），即使开始时间更晚"
        )
    }

    /// 同时刻按标题稳定排序，避免刷新时列表抖动
    func testPanelSortTieBreaksByTitle() {
        let a = makeEvent(id: "a", startDate: date(2026, 10, 23, 8))
        let b = makeEvent(id: "b", startDate: date(2026, 10, 23, 8))
        let sorted = DesktopTodoPanelSort.sort([b, a])
        XCTAssertEqual(sorted.map(\.eventID), ["a", "b"], "makeEvent 标题为 t-a/t-b，同刻按标题稳定")
    }

    func testPanelSortTwoNoDatesTieBreakByTitle() {
        let n1 = makeEvent(id: "n1", startDate: nil)
        let n2 = makeEvent(id: "n2", startDate: nil)
        let sorted = DesktopTodoPanelSort.sort([n2, n1])
        XCTAssertEqual(sorted.map(\.eventID), ["n1", "n2"], "无日期组内按标题稳定")
    }
}
