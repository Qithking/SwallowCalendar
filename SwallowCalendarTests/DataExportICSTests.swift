//
//  DataExportICSTests.swift
//  SwallowCalendarTests
//
//  BUG-15 回归：导出全天事件时 DTEND 不得多加一天。
//  EventKit 的全天事件 endDate 已是 exclusive（次日零点），原实现无条件 +1 天，
//  导致导出的单日全天事件跨两天。
//

import XCTest
@testable import SwallowCalendar

final class DataExportICSTests: XCTestCase {

    private let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()

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

    private func dtendLine(in ics: String) -> String? {
        ics.components(separatedBy: "\r\n").first { $0.hasPrefix("DTEND;VALUE=DATE:") }
    }

    /// EK 语义：单日全天 start=当天零点、end=次日零点 → DTEND 应等于次日，不再 +1 天
    func testAllDayExportDoesNotAddExtraDay() {
        let day0 = Calendar.current.startOfDay(for: Date())
        let day1 = Calendar.current.date(byAdding: .day, value: 1, to: day0)!
        let ics = DataExportSettingsView.generateICS(events: [makeAllDayEvent(start: day0, end: day1)])

        XCTAssertEqual(
            dtendLine(in: ics),
            "DTEND;VALUE=DATE:\(dateOnlyFormatter.string(from: day1))",
            "全天事件 DTEND 应为次日零点（不得再多加一天）"
        )
    }

    /// 零长全天（endDate == start，应用内创建口径）→ 仍按单日补 +1 天（RFC5545 DTEND 为 exclusive）
    func testZeroLengthAllDayExportAddsOneDay() {
        let day0 = Calendar.current.startOfDay(for: Date())
        let ics = DataExportSettingsView.generateICS(events: [makeAllDayEvent(start: day0, end: nil)])

        let expected = Calendar.current.date(byAdding: .day, value: 1, to: day0)!
        XCTAssertEqual(
            dtendLine(in: ics),
            "DTEND;VALUE=DATE:\(dateOnlyFormatter.string(from: expected))"
        )
    }
}
