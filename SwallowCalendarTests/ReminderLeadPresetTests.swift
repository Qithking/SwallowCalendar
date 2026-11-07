//
//  ReminderLeadPresetTests.swift
//  SwallowCalendarTests
//
//  提前提醒 9 项对齐：预设换算、自定义、EK 闹钟、回流与长提前量调度
//

import XCTest
import SwiftData
import EventKit
@testable import SwallowCalendar

@MainActor
final class ReminderLeadPresetTests: XCTestCase {

    // MARK: - 9 项预设换算

    func testPresetTitlesMatchRemindersApp() {
        XCTAssertEqual(
            ReminderLeadPreset.allCases.map(\.title),
            ["无", "1天前", "2天前", "1周前", "2周前", "1个月前", "3个月前", "6个月前", "自定义"]
        )
    }

    func testPresetOffsetMinutesMapping() {
        let expected: [ReminderLeadPreset: Int] = [
            .oneDay: 1440,
            .twoDays: 2880,
            .oneWeek: 10080,
            .twoWeeks: 20160,
            .oneMonth: 43200,
            .threeMonths: 129600,
            .sixMonths: 259200,
        ]
        for (preset, minutes) in expected {
            XCTAssertEqual(preset.offsetMinutes, minutes, "\(preset.title) 分钟映射错误")
        }
        XCTAssertNil(ReminderLeadPreset.none.offsetMinutes)
        XCTAssertNil(ReminderLeadPreset.custom.offsetMinutes)
        XCTAssertEqual(ReminderLeadPreset.resolve(offsets: []), .none)
        XCTAssertEqual(ReminderLeadPreset.resolve(offsets: [0]), .none)
        XCTAssertEqual(ReminderLeadPreset.resolve(offsets: [259200]), .sixMonths)
        XCTAssertEqual(ReminderLeadPreset.resolve(offsets: [5, 10]), .custom)
    }

    // MARK: - 自定义提前/延后与单位换算

    func testCustomDirectionAndUnitConversion() {
        XCTAssertEqual(ReminderLeadUnit.minute.minutesPerUnit, 1)
        XCTAssertEqual(ReminderLeadUnit.hour.minutesPerUnit, 60)
        XCTAssertEqual(ReminderLeadUnit.day.minutesPerUnit, 1440)
        XCTAssertEqual(ReminderLeadUnit.week.minutesPerUnit, 10080)
        XCTAssertEqual(ReminderLeadUnit.month.minutesPerUnit, 43200)

        // 3 小时提前 / 2 天延后
        XCTAssertEqual(ReminderLeadDirection.before.sign * 3 * ReminderLeadUnit.hour.minutesPerUnit, 180)
        XCTAssertEqual(ReminderLeadDirection.after.sign * 2 * ReminderLeadUnit.day.minutesPerUnit, -2880)
    }

    // MARK: - 存量数据与模型钳制

    func testLegacyOverLimitOffsetsAreRestored() {
        let event = makeEvent(id: "legacy")
        event.reminderOffsetsJSON = "[2880,0]"
        // 解除 BUG-07 的 1440 钳制：2 天前必须原样保留
        XCTAssertEqual(event.reminderOffsets, [0, 2880])
    }

    func testOffsetsSetterKeepsLongLeadAndSignedValues() {
        let event = makeEvent(id: "signed")
        event.reminderOffsets = [2880, 0, -1440, 1440, 2880]
        XCTAssertEqual(event.reminderOffsets, [-1440, 0, 1440, 2880])
        XCTAssertEqual(event.reminderMinutes, 2880)
    }

    func testEmptyOffsetsMeansNoEarlyReminder() {
        let event = makeEvent(id: "none")
        event.reminderOffsets = [1440]
        event.reminderOffsets = []
        XCTAssertNil(event.reminderOffsetsJSON)
        XCTAssertEqual(event.reminderMinutes, 0)
        XCTAssertEqual(event.reminderOffsets, [], "无提前提醒返回空数组，不再 fallback [0]")
    }

    // MARK: - EK 闹钟写入与回流

    func testMakeAlarmsReminderPathWritesAbsoluteDue() {
        let due = Date(timeIntervalSince1970: 1_793_260_000)
        let alarms = CalendarService.makeAlarms(offsets: [2880, 0, -60], minutes: nil, reminderDueDate: due)
        XCTAssertEqual(alarms.count, 1, "方案 B：提醒路径仅写一条准点闹钟")
        // 防回归核心：带 offset 的事项写出的 EK 闹钟触发日期 == due 准点，offset 不写入 EK
        XCTAssertEqual(alarms[0].absoluteDate, due, "EK 闹钟触发日期必须 == due 准点")
        XCTAssertEqual(alarms[0].relativeOffset, 0, "不写相对偏移，提前量仅本地存储由应用内提前弹窗消费")
    }

    func testMakeAlarmsEventPathKeepsRelativeOffsets() {
        let alarms = CalendarService.makeAlarms(offsets: [2880, 0, -60], minutes: nil, reminderDueDate: nil)
        XCTAssertEqual(alarms.count, 3)
        // 事件路径（reminderDueDate 为空）保持逐档相对闹钟语义：归一化升序写入
        XCTAssertEqual(alarms.map { Int(-$0.relativeOffset / 60) }, [-60, 0, 2880])
        XCTAssertTrue(alarms.allSatisfy { $0.absoluteDate == nil }, "事件路径不写 absolute 闹钟")
    }

    func testMakeAlarmsNoReminderIsEmpty() {
        let due = Date(timeIntervalSince1970: 1_793_260_000)
        XCTAssertTrue(CalendarService.makeAlarms(offsets: nil, minutes: nil, reminderDueDate: due).isEmpty)
        XCTAssertTrue(CalendarService.makeAlarms(offsets: nil, minutes: 0, reminderDueDate: due).isEmpty)
    }

    func testExtractOffsetsRoundTripIncludesZeroAndAfter() {
        let alarms = [
            EKAlarm(relativeOffset: -1_296_000), // 15 天
            EKAlarm(relativeOffset: -172_800),   // 2 天
            EKAlarm(relativeOffset: 0),          // 到点
            EKAlarm(relativeOffset: 3_600),      // 延后 1 小时
        ]
        XCTAssertEqual(CalendarService.extractReminderOffsets(from: alarms), [-60, 0, 2880, 21600])
    }

    @MainActor
    func testExternalRelativeAlarmFlowsBack() {
        let existing = makeEvent(id: "rem-sync")
        existing.isReminder = true
        existing.reminderOffsets = [1440]

        let ek = CalendarEvent(
            id: "rem-sync",
            title: "同步提醒",
            startDate: existing.startDate,
            endDate: existing.endDate,
            isAllDay: false,
            calendarID: "reminder",
            calendarTitle: "提醒",
            calendarColorHex: "#FF9500",
            category: .user,
            isCompleted: false,
            priority: 0,
            isReminder: true,
            recurrenceType: .none,
            reminderMinutes: 2880,
            reminderOffsets: [2880],
            reminderAlarmIsAbsolute: false,
            eventColorHex: nil
        )
        EventCacheService.mergeReminderUpdate(existing: existing, ek: ek)
        XCTAssertEqual(existing.reminderOffsets, [2880], "外部改为 2 天前应回流到缓存")
        XCTAssertEqual(existing.reminderMinutes, 2880)
    }

    // MARK: - 长提前量调度

    private let anchor = Date(timeIntervalSince1970: 1_793_260_000)

    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: CachedEvent.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = container.mainContext
    }

    override func tearDownWithError() throws {
        container = nil
        context = nil
    }

    func testScheduleWindowCoversSixMonthsLead() {
        let window = ReminderAlertService.scheduleWindow(now: anchor)
        let sixMonthsStart = anchor.addingTimeInterval(TimeInterval(259200 * 60))
        XCTAssertLessThanOrEqual(sixMonthsStart, window.upper, "6 个月提前量的事件必须进入调度窗口")
        XCTAssertGreaterThanOrEqual(window.lower, anchor.addingTimeInterval(-TimeInterval(525600 * 60)))
    }

    func testSixMonthsLeadEntersNextTriggerCandidates() throws {
        let start = anchor.addingTimeInterval(TimeInterval(200 * 24 * 3600))
        let event = makeEvent(id: "long-lead", start: start, offsets: [259200])
        try context.save()

        let next = ReminderAlertService.nextTriggerTime(
            now: anchor, events: [event], snoozeRecords: [], context: context
        )
        XCTAssertEqual(next, start.addingTimeInterval(TimeInterval(-259200 * 60)), "6 个月提前档应成为下次触发时刻")
    }

    func testOneMonthLeadEntersNextTriggerCandidates() throws {
        let start = anchor.addingTimeInterval(TimeInterval(60 * 24 * 3600))
        let event = makeEvent(id: "month-lead", start: start, offsets: [43200])
        try context.save()

        let next = ReminderAlertService.nextTriggerTime(
            now: anchor, events: [event], snoozeRecords: [], context: context
        )
        XCTAssertEqual(next, start.addingTimeInterval(TimeInterval(-43200 * 60)))
    }

    // MARK: - 0 与无、多级组合

    func testNoReminderStillFiresAtOnset() throws {
        let start = anchor.addingTimeInterval(600)
        let event = makeEvent(id: "none-onset", start: start, offsets: [])
        try context.save()

        let next = ReminderAlertService.nextTriggerTime(
            now: anchor, events: [event], snoozeRecords: [], context: context
        )
        XCTAssertEqual(next, start, "无提前提醒仍在到期时刻触发（隐式到点档）")
    }

    func testMultiLevelCombinationUsesEarliest() throws {
        let start = anchor.addingTimeInterval(TimeInterval(10 * 24 * 3600))
        let event = makeEvent(id: "multi", start: start, offsets: [0, 1440, 2880])
        try context.save()

        let next = ReminderAlertService.nextTriggerTime(
            now: anchor, events: [event], snoozeRecords: [], context: context
        )
        XCTAssertEqual(next, start.addingTimeInterval(TimeInterval(-2880 * 60)))
    }

    func testOffsetLabels() {
        XCTAssertEqual(ReminderLeadPreset.label(for: 0), "到点")
        XCTAssertEqual(ReminderLeadPreset.label(for: 1440), "1天前")
        XCTAssertEqual(ReminderLeadPreset.label(for: 2880), "2天前")
        XCTAssertEqual(ReminderLeadPreset.label(for: 43200), "1个月前")
        XCTAssertEqual(ReminderLeadPreset.label(for: -1440), "1天后")
        XCTAssertEqual(ReminderLeadPreset.label(for: 45), "45分钟前")
    }

    // MARK: - Helpers

    private func makeEvent(id: String, start: Date? = nil, offsets: [Int]? = nil) -> CachedEvent {
        let event = CachedEvent(
            eventID: id,
            title: "提醒-\(id)",
            startDate: start ?? anchor.addingTimeInterval(3600),
            endDate: (start ?? anchor.addingTimeInterval(3600)).addingTimeInterval(600),
            isAllDay: false,
            calendarID: "test",
            calendarTitle: "测试日历",
            calendarColorHex: "#007AFF",
            category: .user
        )
        if let offsets { event.reminderOffsets = offsets }
        context.insert(event)
        return event
    }
}
