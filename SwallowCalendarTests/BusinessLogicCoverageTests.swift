//
//  BusinessLogicCoverageTests.swift
//  SwallowCalendarTests
//
//  全应用业务逻辑覆盖补齐（2026-11-07）：
//  订阅 ICS 解析边界、导出 ICS 转义/时刻格式、缓存查询四档语义、
//  稍后提醒覆盖语义、启动过期弹窗「被隐藏行不标已提醒」。
//

import XCTest
import SwiftData
@testable import SwallowCalendar

@MainActor
final class BusinessLogicCoverageTests: XCTestCase {

    private let alertedIDsKey = "ReminderAlertService.lastAlertedEventIDs"
    private let lastCheckTimeKey = "ReminderAlertService.lastCheckTime"
    private let snoozeRecordsKey = "ReminderAlertService.snoozeRecords"

    override func setUp() async throws {
        resetReminderState()
    }

    override func tearDown() async throws {
        resetReminderState()
    }

    private func resetReminderState() {
        ReminderAlertService.shared.resetForTesting()
        UserDefaults.standard.removeObject(forKey: alertedIDsKey)
        UserDefaults.standard.removeObject(forKey: lastCheckTimeKey)
        UserDefaults.standard.removeObject(forKey: snoozeRecordsKey)
        ReminderAlertWindowController.shared.close()
    }

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: CachedEvent.self, configurations: config)
    }

    @discardableResult
    private func insertOverdueEvent(
        _ context: ModelContext,
        eventID: String,
        startDate: Date
    ) throws -> CachedEvent {
        let event = CachedEvent(
            eventID: eventID,
            title: eventID,
            startDate: startDate,
            endDate: startDate,
            isAllDay: false,
            calendarID: "test",
            calendarTitle: "测试日历",
            calendarColorHex: "#007AFF",
            category: .user
        )
        context.insert(event)
        try context.save()
        return event
    }

    // MARK: - 订阅 ICS 解析边界

    /// B-20 行折叠：续行必须并入上一条字段，否则长摘要/UID 会丢失或解析失败
    func testParseICSUnfoldsContinuationLines() throws {
        let content = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VEVENT
        SUMMARY:会议
         纪要
        UID:folded-
         uid
        DTSTART:20261201T090000
        END:VEVENT
        END:VCALENDAR
        """
        let events = try ICSService.shared.parseICS(content)
        XCTAssertEqual(events.count, 1, "折叠行不得导致事件丢失")
        XCTAssertEqual(events.first?.summary, "会议纪要", "续行应拼回完整摘要")
        XCTAssertEqual(events.first?.uid, "folded-uid", "续行应拼回完整 UID")
    }

    /// B-20 TZID：非 UTC 的订阅日程必须按指定时区换算，不能整体偏移
    func testParseICSUsesTZIDForTimedEvent() throws {
        let content = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VEVENT
        SUMMARY:时区事件
        UID:tzid-1
        DTSTART;TZID=Asia/Shanghai:20261201T090000
        DTEND;TZID=Asia/Shanghai:20261201T100000
        END:VEVENT
        END:VCALENDAR
        """
        let events = try ICSService.shared.parseICS(content)
        let event = try XCTUnwrap(events.first)
        XCTAssertFalse(event.isAllDay)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let expected = calendar.date(from: DateComponents(
            year: 2026, month: 12, day: 1, hour: 9, minute: 0
        ))
        XCTAssertEqual(event.startDate, expected, "09:00 上海时间应换算为对应绝对时刻")
    }

    /// 时间值区取最后一个冒号之后：TZID 参数自身含冒号时不得把参数尾段当日期
    func testParseICSTakesDateAfterLastColonWhenTZIDContainsColon() throws {
        let content = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VEVENT
        SUMMARY:参数含冒号
        UID:tzid-colon
        DTSTART;TZID=(UTC+08:00) Beijing:20261201T090000
        END:VEVENT
        END:VCALENDAR
        """
        let events = try ICSService.shared.parseICS(content)
        let event = try XCTUnwrap(events.first)
        // TZID 无法识别时回退本地时区，但日期值必须来自最后一个冒号之后
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let expected = calendar.date(from: DateComponents(
            year: 2026, month: 12, day: 1, hour: 9, minute: 0
        ))
        XCTAssertEqual(event.startDate, expected)
        XCTAssertFalse(event.isAllDay, "含 T 的值应判定为定时事件")
    }

    /// 非法日期只让该字段为 nil，不得丢弃事件或让整份订阅解析失败
    func testParseICSInvalidDateKeepsEventWithNilField() throws {
        let content = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VEVENT
        SUMMARY:坏日期
        UID:bad-date
        DTSTART:not-a-date
        END:VEVENT
        END:VCALENDAR
        """
        let events = try ICSService.shared.parseICS(content)
        XCTAssertEqual(events.count, 1, "单字段非法不应丢弃整条事件")
        XCTAssertNil(events.first?.startDate)
    }

    /// 缺少 END:VEVENT 的截断事件必须丢弃（不得把半条记录入库）
    func testParseICSDiscardsUnterminatedEvent() throws {
        let content = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VEVENT
        SUMMARY:半条事件
        UID:unterminated
        END:VCALENDAR
        """
        XCTAssertEqual(try ICSService.shared.parseICS(content).count, 0)
    }

    // MARK: - ICS TEXT 反转义

    /// `\,` 应还原为逗号（订阅标题里最常见的转义）
    func testParseICSUnescapesComma() throws {
        let events = try ICSService.shared.parseICS(singleEvent(summary: #"会议\,纪要"#, uid: "unescape-comma"))
        XCTAssertEqual(events.first?.summary, "会议,纪要")
    }

    /// `\;` 应还原为分号
    func testParseICSUnescapesSemicolon() throws {
        let events = try ICSService.shared.parseICS(singleEvent(summary: #"a\;b"#, uid: "unescape-semicolon"))
        XCTAssertEqual(events.first?.summary, "a;b")
    }

    /// `\\` 应还原为单个反斜杠
    func testParseICSUnescapesBackslash() throws {
        let events = try ICSService.shared.parseICS(singleEvent(summary: #"a\\b"#, uid: "unescape-backslash"))
        XCTAssertEqual(events.first?.summary, #"a\b"#)
    }

    /// `\n` 与 `\N` 都应还原为换行（保留两行结构）
    func testParseICSUnescapesNewlines() throws {
        let content = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VEVENT
        SUMMARY:a\\nb
        UID:unescape-lf
        END:VEVENT
        BEGIN:VEVENT
        SUMMARY:c\\Nd
        UID:unescape-upper
        END:VEVENT
        END:VCALENDAR
        """
        let events = try ICSService.shared.parseICS(content)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].summary, "a\nb")
        XCTAssertEqual(events[1].summary, "c\nd")
    }

    /// 未知转义不得吞掉反斜杠：`\q` 保持原样
    func testParseICSKeepsUnknownEscape() throws {
        let events = try ICSService.shared.parseICS(singleEvent(summary: #"a\qb"#, uid: "unescape-unknown"))
        XCTAssertEqual(events.first?.summary, #"a\qb"#)
    }

    /// 末尾孤立反斜杠必须保留，不能因越界被丢弃或崩溃
    func testParseICSKeepsTrailingBackslash() throws {
        let events = try ICSService.shared.parseICS(singleEvent(summary: #"a\"#, uid: "unescape-trailing"))
        XCTAssertEqual(events.first?.summary, #"a\"#)
    }

    /// 同一反转义入口必须用于全部 TEXT 字段：SUMMARY 与 UID 同时还原
    func testParseICSUnescapesUIDWithSameEntry() throws {
        let events = try ICSService.shared.parseICS(singleEvent(summary: #"标题\,一"#, uid: #"uid\,1"#))
        XCTAssertEqual(events.first?.summary, "标题,一")
        XCTAssertEqual(events.first?.uid, "uid,1")
    }

    private func singleEvent(summary: String, uid: String) -> String {
        """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VEVENT
        SUMMARY:\(summary)
        UID:\(uid)
        DTSTART:20261201T090000
        END:VEVENT
        END:VCALENDAR
        """
    }

    // MARK: - 导出 ICS

    /// RFC5545 文本转义：反斜杠、逗号、分号、换行必须转义，裸 CR 必须移除
    func testGenerateICSEscapesSummarySpecialCharacters() throws {
        let title = "备份,归档;说明\\路径\n第二行\r残留"
        let events = [
            makeEvent(id: "escape-1", title: title, isAllDay: false)
        ]
        let ics = DataExportSettingsView.generateICS(events: events)
        let summaryLine = try XCTUnwrap(
            ics.components(separatedBy: "\r\n").first { $0.hasPrefix("SUMMARY:") }
        )

        XCTAssertTrue(summaryLine.contains("备份\\,归档"), "逗号必须转义为 \\,")
        XCTAssertTrue(summaryLine.contains("归档\\;说明"), "分号必须转义为 \\;")
        XCTAssertTrue(summaryLine.contains("说明\\\\路径"), "反斜杠必须转义为 \\\\")
        XCTAssertTrue(summaryLine.contains("路径\\n第二行"), "换行必须转义为 \\n")
        XCTAssertFalse(summaryLine.contains("\r"), "裸 CR 必须移除")
        XCTAssertEqual(ics.components(separatedBy: "\r\n").count > 1, true, "ICS 必须使用 CRLF 分行")
    }

    /// 定时事件：DTSTART/DTEND 使用 UTC（Z 后缀），且 UID 必带
    func testGenerateICSWritesUTCTimestampsAndUID() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(3600)
        let events = [
            makeEvent(id: "timed-1", title: "定时", start: start, end: end, isAllDay: false)
        ]
        let ics = DataExportSettingsView.generateICS(events: events)

        XCTAssertTrue(ics.contains("UID:timed-1"))
        XCTAssertTrue(ics.contains("DTSTART:\(utcString(start))"))
        XCTAssertTrue(ics.contains("DTEND:\(utcString(end))"))
        XCTAssertTrue(ics.hasSuffix("END:VCALENDAR"))
    }

    /// 定时事件缺少结束时间时按零长事件导出（DTEND = DTSTART），不得省略 DTEND
    func testGenerateICSDefaultsMissingEndToStart() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let events = [makeEvent(id: "no-end", title: "无结束", start: start, end: nil, isAllDay: false)]
        let ics = DataExportSettingsView.generateICS(events: events)

        XCTAssertTrue(ics.contains("DTSTART:\(utcString(start))"))
        XCTAssertTrue(ics.contains("DTEND:\(utcString(start))"), "缺失结束时间应按零长导出")
    }

    private func makeEvent(
        id: String,
        title: String,
        start: Date? = Date(timeIntervalSince1970: 1_800_000_000),
        end: Date? = Date(timeIntervalSince1970: 1_800_000_600),
        isAllDay: Bool
    ) -> CalendarEvent {
        CalendarEvent(
            id: id,
            title: title,
            startDate: start,
            endDate: end,
            isAllDay: isAllDay,
            calendarID: "test",
            calendarTitle: "测试日历",
            calendarColorHex: "#007AFF",
            category: .user,
            isCompleted: false,
            priority: 0,
            isReminder: false,
            recurrenceType: .none,
            reminderMinutes: 0,
            eventColorHex: nil
        )
    }

    private func utcString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    // MARK: - 缓存查询四档语义（成功路径）

    /// perform 成功时必须原样返回结果，不得包装或吞掉
    func testCacheFetchPerformPassesThroughSuccess() throws {
        XCTAssertEqual(try CacheFetch.perform(operation: "成功") { 42 }, 42)
    }

    /// optional / degradeToEmpty / countDegradingToZero 在查询成功时返回真实数据
    func testCacheFetchReadVariantsReturnRealDataOnSuccess() throws {
        let container = try makeContainer()
        let context = container.mainContext
        try insertOverdueEvent(context, eventID: "cache-1", startDate: Date())
        try insertOverdueEvent(context, eventID: "cache-2", startDate: Date())
        let descriptor = FetchDescriptor<CachedEvent>()

        XCTAssertEqual(CacheFetch.optional(descriptor, in: context, operation: "optional")?.count, 2)
        XCTAssertEqual(
            CacheFetch.degradeToEmpty(descriptor, in: context, operation: "降级为空", reason: "测试").count,
            2,
            "成功路径不得走降级分支"
        )
        XCTAssertEqual(
            CacheFetch.countDegradingToZero(descriptor, in: context, operation: "计数"),
            2,
            "计数成功时必须返回真实条数而非 0"
        )
    }

    // MARK: - 稍后提醒
    /// 同一事件重复稍后提醒只保留一条记录，且以最后一次的时间为准（覆盖语义）
    func testSnoozeOverwritesPreviousRecordForSameEvent() {
        ReminderAlertService.shared.snooze(eventID: "snooze-1", minutes: 10)
        let first = ReminderAlertService.loadSnoozeRecords()
        XCTAssertEqual(first.count, 1)

        ReminderAlertService.shared.snooze(eventID: "snooze-1", minutes: 30)
        let second = ReminderAlertService.loadSnoozeRecords()

        XCTAssertEqual(second.count, 1, "重复稍后提醒不得堆积多条记录")
        XCTAssertEqual(second.first?.eventID, "snooze-1")
        XCTAssertGreaterThan(
            second.first?.fireDate ?? .distantPast,
            first.first?.fireDate ?? .distantPast,
            "应以最后一次设定的提醒时刻为准"
        )
    }

    // MARK: - 启动过期弹窗上限

    /// H2 去重键口径：超上限被隐藏的行不得写入已提醒键，否则重启后也不会再提醒
    func testHiddenExpiredRowsAreNotMarkedAlerted() async throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        let now = Date()
        for index in 0..<35 {
            try insertOverdueEvent(
                container.mainContext,
                eventID: "row-\(index)",
                startDate: now.addingTimeInterval(-Double(index) * 60)
            )
        }

        await ReminderAlertService.shared.checkExpiredEvents()

        XCTAssertTrue(ReminderAlertWindowController.shared.isWindowVisible, "过期提醒应弹出")
        let keys = UserDefaults.standard.stringArray(forKey: alertedIDsKey) ?? []
        XCTAssertEqual(keys.count, 30, "上限 30 条：只应为实际展示行写去重键")
        let alertedIDs = Set(keys.compactMap { $0.split(separator: "|").first.map(String.init) })
        XCTAssertTrue(alertedIDs.contains("row-0"), "最近过期的 30 条应展示并标已提醒")
        XCTAssertTrue(alertedIDs.contains("row-29"))
        XCTAssertFalse(alertedIDs.contains("row-30"), "被隐藏的较早行不得标已提醒")
        XCTAssertFalse(alertedIDs.contains("row-34"))
    }
}
