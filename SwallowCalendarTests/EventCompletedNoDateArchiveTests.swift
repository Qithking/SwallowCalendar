//
//  EventCompletedNoDateArchiveTests.swift
//  SwallowCalendarTests
//
//  无到期时间的已办任务按「标记完成时间」归档回归：
//  修复前已办列表对 startDate == nil 的任务全 tab 放行（includeNoDateReminders
//  绕过日期范围），且完成时间从未存储（CachedEvent/CalendarEvent 无 completedAt），
//  导致无到期时间已办在今天/本周/本月/本年/全部所有 tab 重复出现。
//  防线：completedAt 全链路落库（EK completionDate 采集 + toggle 写入），
//  已办过滤按 completedAt 归档；无完成时间的存量仅在「全部」可见。
//

import XCTest
@testable import SwallowCalendar

@MainActor
final class EventCompletedNoDateArchiveTests: XCTestCase {

    /// 基准日期：2026-11-11 12:00（周三）
    private let base: Date = {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 11
        comps.day = 11
        comps.hour = 12
        return Calendar.current.date(from: comps)!
    }()

    private func range(_ mode: EventFilterMode) -> (start: Date, end: Date) {
        mode.dateRange(from: base)
    }

    /// 构造已办用户事项（标题非空默认满足基础过滤）
    private func makeEvent(
        startDate: Date?,
        completedAt: Date?,
        isCompleted: Bool = true,
        category: EventCategory = .user
    ) -> CalendarEvent {
        CalendarEvent(
            id: UUID().uuidString,
            title: "搭建 vpn",
            startDate: startDate,
            endDate: startDate,
            isAllDay: true,
            calendarID: "reminder",
            calendarTitle: "提醒",
            calendarColorHex: "#FF9500",
            category: category,
            isCompleted: isCompleted,
            priority: 0,
            isReminder: true,
            recurrenceType: .none,
            reminderMinutes: 0,
            eventColorHex: nil,
            completedAt: completedAt
        )
    }

    // MARK: - 有到期时间已办（现有行为不回归）

    /// 有到期时间的已办按 startDate 归档：今天范围内可见
    func testDatedCompletedEventVisibleInToday() {
        let event = makeEvent(
            startDate: Calendar.current.date(byAdding: .hour, value: -2, to: base),
            completedAt: nil
        )
        XCTAssertTrue(EventCompletedListView.shouldInclude(event, in: range(.today), filterMode: .today))
    }

    // MARK: - 无到期时间已办按完成时间归档（核心回归）

    /// 无日期已办：完成时间在今天的「今天」范围内 → 今天可见
    func testNoDateCompletedWithCompletionTimeInToday() {
        let event = makeEvent(
            startDate: nil,
            completedAt: Calendar.current.date(byAdding: .hour, value: -3, to: base)
        )
        XCTAssertTrue(EventCompletedListView.shouldInclude(event, in: range(.today), filterMode: .today))
        // 同一完成时间也应归入本月/本年/全部（更大的包含范围）
        XCTAssertTrue(EventCompletedListView.shouldInclude(event, in: range(.thisMonth), filterMode: .thisMonth))
        XCTAssertTrue(EventCompletedListView.shouldInclude(event, in: range(.all), filterMode: .all))
    }

    /// 无日期已办：完成时间不在当前 tab 范围 → 该 tab 不再出现（修复前全 tab 放行）
    func testNoDateCompletedOutsideRangeFilteredOut() {
        // 完成于 10 天前：不在今天、不在本周（含 base 的周），只归历史
        let event = makeEvent(
            startDate: nil,
            completedAt: Calendar.current.date(byAdding: .day, value: -10, to: base)
        )
        XCTAssertFalse(EventCompletedListView.shouldInclude(event, in: range(.today), filterMode: .today))
        XCTAssertFalse(EventCompletedListView.shouldInclude(event, in: range(.thisWeek), filterMode: .thisWeek))
        // 「全部」范围恒包含一切完成时间
        XCTAssertTrue(EventCompletedListView.shouldInclude(event, in: range(.all), filterMode: .all))
    }

    /// 无日期已办：完成时间缺省（存量未同步补全）→ 仅「全部」可见
    func testNoDateCompletedWithoutCompletionTimeOnlyInAll() {
        let event = makeEvent(startDate: nil, completedAt: nil)
        XCTAssertFalse(EventCompletedListView.shouldInclude(event, in: range(.today), filterMode: .today))
        XCTAssertFalse(EventCompletedListView.shouldInclude(event, in: range(.thisWeek), filterMode: .thisWeek))
        XCTAssertFalse(EventCompletedListView.shouldInclude(event, in: range(.thisMonth), filterMode: .thisMonth))
        XCTAssertFalse(EventCompletedListView.shouldInclude(event, in: range(.thisYear), filterMode: .thisYear))
        XCTAssertTrue(EventCompletedListView.shouldInclude(event, in: range(.all), filterMode: .all))
    }

    // MARK: - 基础过滤（现有行为不回归）

    /// 未完成事项不进已办列表
    func testUncompletedEventFilteredOut() {
        let event = makeEvent(
            startDate: Calendar.current.date(byAdding: .hour, value: -2, to: base),
            completedAt: nil,
            isCompleted: false
        )
        XCTAssertFalse(EventCompletedListView.shouldInclude(event, in: range(.today), filterMode: .today))
    }

    /// 非用户分类（系统/订阅）不进已办列表
    func testNonUserCategoryFilteredOut() {
        let event = makeEvent(
            startDate: Calendar.current.date(byAdding: .hour, value: -2, to: base),
            completedAt: nil,
            category: .system
        )
        XCTAssertFalse(EventCompletedListView.shouldInclude(event, in: range(.today), filterMode: .today))
    }
}
