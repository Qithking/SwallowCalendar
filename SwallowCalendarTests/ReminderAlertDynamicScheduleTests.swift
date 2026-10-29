//
//  ReminderAlertDynamicScheduleTests.swift
//  SwallowCalendarTests
//
//  bug: due-alert-punctual-scheduling
//  需求：应用内提醒应准点弹出（问题1：面板倒计时停在 0 后最长再等 60s 才弹窗；
//        问题3：事项到期提醒弹框不及时）——现状 60s 轮询最坏延迟 60 秒
//  方案：ReminderAlertService 按最近未提醒 alertTime（含 snooze fireDate）动态
//        调度单次准点 timer，60s 轮询保留作兜底；nextTriggerTime 纯函数承载
//        「下一次触发时刻」计算，本文件锁其语义
//

import XCTest
import SwiftData
@testable import SwallowCalendar

@MainActor
final class ReminderAlertDynamicScheduleTests: XCTestCase {

    /// 固定锚点，避免真实时钟波动
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

    /// 构造用户分类未完成事项（offsets 经 setter 维护 reminderMinutes 硬不变量）
    private func makeEvent(id: String, start: Date, offsets: [Int]? = nil, skipHolidays: Bool = false) -> CachedEvent {
        let event = CachedEvent(
            eventID: id,
            title: "调度-\(id)",
            startDate: start,
            endDate: start.addingTimeInterval(600),
            isAllDay: false,
            calendarID: "test",
            calendarTitle: "测试日历",
            calendarColorHex: "#007AFF",
            category: .user
        )
        if let offsets { event.reminderOffsets = offsets }
        event.skipHolidays = skipHolidays
        context.insert(event)
        return event
    }

    /// N-1 提前档与准点档均在未来 → 取更早的提前档（start-5min）
    func testEarliestFutureOffsetTierWins() throws {
        let start = anchor.addingTimeInterval(600)
        let event = makeEvent(id: "n1", start: start, offsets: [5])
        try context.save()

        let next = ReminderAlertService.nextTriggerTime(
            now: anchor, events: [event],
            snoozeRecords: [], context: context
        )
        XCTAssertEqual(next, start.addingTimeInterval(-5 * 60), "下次触发应为准点前的提前档")
    }

    /// N-2 未设置提醒 → 隐式准点档 alertTime=startDate（与常规检查 fallback [0] 同口径）
    func testUnsetReminderTriggersAtOnset() throws {
        let start = anchor.addingTimeInterval(600)
        let event = makeEvent(id: "n2", start: start)
        try context.save()

        let next = ReminderAlertService.nextTriggerTime(
            now: anchor, events: [event], snoozeRecords: [], context: context
        )
        XCTAssertEqual(next, start, "未设置提醒的事件应在事件开始时刻触发")
    }

    /// N-3 已过去的档位不参与：30 档已过 → 准点档（未来）为下次触发
    func testPastTiersExcluded() throws {
        let start = anchor.addingTimeInterval(5 * 60)
        let event = makeEvent(id: "n3", start: start, offsets: [30, 0])
        try context.save()

        let next = ReminderAlertService.nextTriggerTime(
            now: anchor, events: [event], snoozeRecords: [], context: context
        )
        XCTAssertEqual(next, start, "过去档位应被剔除，取最近的未来档")
    }

    /// N-4 snooze fireDate 早于事件档 → snooze 优先（动态调度须含 snooze）
    func testSnoozeFireDateIncluded() throws {
        let start = anchor.addingTimeInterval(600)
        let fire = anchor.addingTimeInterval(120)
        let event = makeEvent(id: "n4", start: start, offsets: [5])
        try context.save()

        let next = ReminderAlertService.nextTriggerTime(
            now: anchor, events: [event],
            snoozeRecords: [SnoozeRecord(eventID: "n4", fireDate: fire)], context: context
        )
        XCTAssertEqual(next, fire, "更早的稍后提醒时刻应为下次触发时刻")
    }

    /// N-5 全部候选均在过去 → nil（无可调度时刻）
    func testNilWhenAllCandidatesPast() throws {
        let start = anchor.addingTimeInterval(-600)
        let event = makeEvent(id: "n5", start: start, offsets: [5, 0])
        try context.save()

        let next = ReminderAlertService.nextTriggerTime(
            now: anchor, events: [event],
            snoozeRecords: [SnoozeRecord(eventID: "n5", fireDate: anchor.addingTimeInterval(-60))],
            context: context
        )
        XCTAssertNil(next, "无未来候选时应返回 nil（60s 轮询兜底）")
    }

    /// N-6 智能跳过（周六 + skipHolidays）的事件不参与调度；同日未勾选对照应命中
    func testHolidaySkippedEventExcluded() throws {
        // 锚点推进到最近的周六（周末规则判定，不依赖节假日数据）
        var saturday = anchor
        while Calendar.current.component(.weekday, from: saturday) != 7 {
            saturday.addTimeInterval(86400)
        }
        let skipped = makeEvent(id: "n6-skip", start: saturday, skipHolidays: true)
        let normal = makeEvent(id: "n6-normal", start: saturday)
        try context.save()

        let nextSkipped = ReminderAlertService.nextTriggerTime(
            now: anchor, events: [skipped], snoozeRecords: [], context: context
        )
        XCTAssertNil(nextSkipped, "智能跳过的事件不应作为准点触发时刻")

        let nextNormal = ReminderAlertService.nextTriggerTime(
            now: anchor, events: [normal], snoozeRecords: [], context: context
        )
        XCTAssertEqual(nextNormal, saturday, "未勾选跳过的对照事件应正常命中准点档")
    }
}
