//
//  DataExportICSTests.swift
//  SwallowCalendarTests
//
//  全天事件导出：内部 endDate 含结束日，DTEND;VALUE=DATE 为 exclusive，
//  导出侧统一 +1 天；仅导出路径生效，非全天事件不受影响。
//

import XCTest
@testable import SwallowCalendar

final class DataExportICSTests: XCTestCase {

    private let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()

    private let utcFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, hour: Int = 23, minute: Int = 59, second: Int = 59) -> Date {
        var comps = DateComponents()
        comps.year = y
        comps.month = m
        comps.day = d
        comps.hour = hour
        comps.minute = minute
        comps.second = second
        return Calendar.current.date(from: comps)!
    }

    private func makeAllDayEvent(start: Date, end: Date?) -> CalendarEvent {
        CalendarEvent(
            id: "all-day-\(start.timeIntervalSince1970)",
            title: "全天事件",
            startDate: start,
            endDate: end,
            isAllDay: true,
            calendarID: "cal",
            calendarTitle: "测试日历",
            calendarColorHex: "#FF9500",
            category: .system,
            isCompleted: false,
            priority: 0,
            isReminder: false,
            recurrenceType: .none,
            reminderMinutes: 0,
            eventColorHex: nil
        )
    }

    private func makeTimedEvent(start: Date, end: Date) -> CalendarEvent {
        CalendarEvent(
            id: "timed-\(start.timeIntervalSince1970)",
            title: "定时事件",
            startDate: start,
            endDate: end,
            isAllDay: false,
            calendarID: "cal",
            calendarTitle: "测试日历",
            calendarColorHex: "#FF9500",
            category: .system,
            isCompleted: false,
            priority: 0,
            isReminder: false,
            recurrenceType: .none,
            reminderMinutes: 0,
            eventColorHex: nil
        )
    }

    private func dtendDateLine(in ics: String) -> String? {
        ics.components(separatedBy: "\r\n").first { $0.hasPrefix("DTEND;VALUE=DATE:") }
    }

    private func dtendLine(in ics: String) -> String? {
        ics.components(separatedBy: "\r\n").first { $0.hasPrefix("DTEND:") }
    }

    private func assertAllDayEnd(_ event: CalendarEvent, expectedDay: Date, file: StaticString = #filePath, line: UInt = #line) {
        let ics = DataExportSettingsView.generateICS(events: [event])
        XCTAssertEqual(
            dtendDateLine(in: ics),
            "DTEND;VALUE=DATE:\(dateOnlyFormatter.string(from: expectedDay))",
            file: file, line: line
        )
    }

    // MARK: - 全天事件：导出侧 +1 天

    /// 单日全天（内部结束时间 23:59:59）→ DTEND 次日
    func testSingleDayAllDayExportAddsOneDay() {
        let day0 = date(2026, 11, 8, hour: 0, minute: 0, second: 0)
        let end = date(2026, 11, 8)
        let event = makeAllDayEvent(start: day0, end: end)
        assertAllDayEnd(event, expectedDay: date(2026, 11, 9, hour: 0, minute: 0, second: 0))
    }

    /// 月末跨月：1 月 31 日 → 2 月 1 日
    func testAllDayExportCrossesMonthEnd() {
        let start = date(2026, 1, 31, hour: 0, minute: 0, second: 0)
        let end = date(2026, 1, 31)
        let event = makeAllDayEvent(start: start, end: end)
        assertAllDayEnd(event, expectedDay: date(2026, 2, 1, hour: 0, minute: 0, second: 0))
    }

    /// 跨年：12 月 31 日 → 次年 1 月 1 日
    func testAllDayExportCrossesYearEnd() {
        let start = date(2026, 12, 31, hour: 0, minute: 0, second: 0)
        let end = date(2026, 12, 31)
        let event = makeAllDayEvent(start: start, end: end)
        assertAllDayEnd(event, expectedDay: date(2027, 1, 1, hour: 0, minute: 0, second: 0))
    }

    /// 连续多日全天：11/6–11/8 → DTEND 11/9（exclusive）
    func testMultiDayAllDayExportAddsOneDayAtEnd() {
        let start = date(2026, 11, 6, hour: 0, minute: 0, second: 0)
        let end = date(2026, 11, 8)
        let event = makeAllDayEvent(start: start, end: end)
        assertAllDayEnd(event, expectedDay: date(2026, 11, 9, hour: 0, minute: 0, second: 0))
    }

    /// 零长全天（end 缺省）仍按单日导出
    func testZeroLengthAllDayExportAddsOneDay() {
        let start = date(2026, 11, 8, hour: 0, minute: 0, second: 0)
        let event = makeAllDayEvent(start: start, end: nil)
        assertAllDayEnd(event, expectedDay: date(2026, 11, 9, hour: 0, minute: 0, second: 0))
    }

    // MARK: - 全天事件：已是 exclusive 写法（次日 00:00）不得再次 +1

    func testAllDayExclusiveMidnightEndIsNotShiftedAgain() {
        let start = date(2026, 11, 6, hour: 0, minute: 0, second: 0)
        let end = date(2026, 11, 9, hour: 0, minute: 0, second: 0)
        let event = makeAllDayEvent(start: start, end: end)
        assertAllDayEnd(event, expectedDay: date(2026, 11, 9, hour: 0, minute: 0, second: 0))
    }

    func testAllDayExclusiveMidnightEndCrossesMonthEnd() {
        let start = date(2026, 1, 31, hour: 0, minute: 0, second: 0)
        let end = date(2026, 2, 1, hour: 0, minute: 0, second: 0)
        let event = makeAllDayEvent(start: start, end: end)
        assertAllDayEnd(event, expectedDay: date(2026, 2, 1, hour: 0, minute: 0, second: 0))
    }

    // MARK: - 非全天不受影响

    func testTimedEventExportUsesOriginalEnd() {
        let start = date(2026, 11, 8, hour: 10, minute: 0, second: 0)
        let end = date(2026, 11, 8, hour: 12, minute: 0, second: 0)
        let ics = DataExportSettingsView.generateICS(events: [makeTimedEvent(start: start, end: end)])
        XCTAssertEqual(
            dtendLine(in: ics),
            "DTEND:\(utcFormatter.string(from: end))",
            "非全天事件的 DTEND 不得做任何日期偏移"
        )
        XCTAssertNil(dtendDateLine(in: ics))
    }
}
