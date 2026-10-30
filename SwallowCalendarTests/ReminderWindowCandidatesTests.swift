//
//  ReminderWindowCandidatesTests.swift
//  SwallowCalendarTests
//
//  bug: window-poll-recurring-base-id-completion
//  R-1：常规 60s 轮询窗口候选中循环 base 行须替换为窗口内展开实例（复合 ID），
//  否则弹窗行携带 base ID → markAsCompleted 经 parseOccurrenceID=nil
//  走整条完成主路径（EK 整条污染、无完成历史、游标不推进），
//  与启动路径（occurrence 级完成）双语义并存
//
//  日期锚点：2026-10-28 周三
//

import XCTest
import SwiftData
@testable import SwallowCalendar

@MainActor
final class ReminderWindowCandidatesTests: XCTestCase {

    private var calendarService: CalendarService!

    override func setUpWithError() throws {
        calendarService = CalendarService()
    }

    override func tearDownWithError() throws {
        calendarService = nil
    }

    /// 仅注册 CachedEvent 的内存 SwiftData 容器
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: CachedEvent.self, configurations: config)
    }

    /// 本地时区日期构造
    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return Calendar.current.date(from: components)!
    }

    /// 构造用户待办并落库
    @discardableResult
    private func insertEvent(
        into context: ModelContext,
        eventID: String,
        title: String,
        startDate: Date?,
        recurrenceType: RecurrenceType = .none,
        completed: [Date] = [],
        originStartDate: Date? = nil
    ) throws -> CachedEvent {
        let event = CachedEvent(
            eventID: eventID,
            title: title,
            startDate: startDate,
            endDate: startDate,
            isAllDay: false,
            calendarID: "test",
            calendarTitle: "测试日历",
            calendarColorHex: "#007AFF",
            category: .user,
            recurrenceType: recurrenceType,
            originStartDate: originStartDate
        )
        event.completedOccurrenceDates = completed
        context.insert(event)
        try context.save()
        return event
    }

    /// 核心 bug：常规窗口候选中循环 base 行被窗口内展开实例（复合 ID）替换，
    /// 弹窗完成才能走 occurrence 级路径；普通单次行原样保留
    func testWindowCandidatesReplaceRecurringBaseWithOccurrenceInstance() throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        let context = container.mainContext
        // daily 09:00，锚点 10/27，游标停 10/28（今日实例未完成）
        try insertEvent(
            into: context,
            eventID: "base-win",
            title: "早上上班",
            startDate: date(2026, 10, 28, 9, 0),
            recurrenceType: .daily,
            originStartDate: date(2026, 10, 27, 9, 0)
        )
        // 同窗口普通单次行
        try insertEvent(into: context, eventID: "single-x", title: "起床", startDate: date(2026, 10, 28, 9, 2))

        // now 取弹窗 tick 时刻（60s 轮询 90s 窗口：now-90s < startDate 才能捞到
        // 今日实例——与真实触发场景一致：alertTime=09:00 到点弹窗、用户点完成）
        let now = date(2026, 10, 28, 9, 1)
        let windowStart = now.addingTimeInterval(-90)
        let upperBound = now.addingTimeInterval(1440 * 60)
        // 模拟 checkDueEvents 常规粗筛结果（B-27 谓词捞到的原始行）
        let raw: [CachedEvent] = try context.fetch(FetchDescriptor<CachedEvent>())

        let candidates = ReminderAlertService.recurringWindowCandidates(
            rawEvents: raw,
            windowStart: windowStart,
            upperBound: upperBound,
            context: context
        )

        // 关键断言：今日 09:00 实例以复合 ID 进入候选（修复前弹窗行是裸 base ID）
        let todayOcc = candidates.first {
            CachedEvent.parseOccurrenceID($0.eventID)?.occurrence == date(2026, 10, 28, 9, 0)
        }
        XCTAssertNotNil(todayOcc, "循环 base 行应替换为窗口内复合 ID 实例；实际候选: \(candidates.map { ($0.eventID, $0.startDate as Any) })")
        XCTAssertEqual(todayOcc?.title, "早上上班")
        XCTAssertEqual(todayOcc?.startDate, date(2026, 10, 28, 9, 0))
        // base 行不再以裸 baseID 出现（避免 markAsCompleted 走整条完成主路径）
        XCTAssertFalse(candidates.contains { $0.eventID == "base-win" })
        // 普通单次行原样保留
        XCTAssertTrue(candidates.contains { $0.eventID == "single-x" })
    }

    /// 已完成历史实例不进常规窗口候选（与启动路径过滤一致）
    func testWindowCandidatesExcludeCompletedOccurrence() throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        let context = container.mainContext
        // 锚点 10/27，10/27 已完成推进到 10/28
        try insertEvent(
            into: context,
            eventID: "base-done",
            title: "早上下班休息",
            startDate: date(2026, 10, 28, 12, 0),
            recurrenceType: .daily,
            completed: [date(2026, 10, 27, 12, 0)],
            originStartDate: date(2026, 10, 27, 12, 0)
        )

        let now = date(2026, 10, 28, 12, 1)
        let candidates = ReminderAlertService.recurringWindowCandidates(
            rawEvents: try context.fetch(FetchDescriptor<CachedEvent>()),
            windowStart: now.addingTimeInterval(-90),
            upperBound: now.addingTimeInterval(1440 * 60),
            context: context
        )

        let occurrences = candidates.compactMap { CachedEvent.parseOccurrenceID($0.eventID)?.occurrence }
        XCTAssertFalse(occurrences.contains(date(2026, 10, 27, 12, 0)), "已完成历史实例不应进入常规窗口候选")
        XCTAssertTrue(candidates.contains {
            CachedEvent.parseOccurrenceID($0.eventID)?.occurrence == date(2026, 10, 28, 12, 0)
        }, "游标实例（未完成）应保留在候选中")
        XCTAssertFalse(candidates.contains { $0.isCompleted }, "候选不含已完成实例")
    }

    // MARK: - P2-2：R-1 升级兼容——去重键 baseID 归一化

    /// 存量键（base 行 ID）与新候选行（复合实例 ID）须识别为同一提醒主体，
    /// 否则 hasAlertedKey 精确匹配脱靶，升级后首个到点周期重复弹
    func testAlertSubjectMatchesBaseIDAcrossRepresentation() {
        XCTAssertTrue(
            ReminderAlertService.sameAlertSubject("base-1", "base-1|occ:1730000000"),
            "base 行 ID 与其复合实例 ID 应视为同一提醒主体"
        )
    }

    /// 不同 base 行互不吞——归一化不得把不同事件的提醒误判为同一主体
    func testAlertSubjectDifferentBaseIDsDoNotMatch() {
        XCTAssertFalse(
            ReminderAlertService.sameAlertSubject("base-1|occ:1730000000", "base-2|occ:1730000000"),
            "不同 base 行的复合 ID 不应匹配"
        )
        XCTAssertFalse(ReminderAlertService.sameAlertSubject("base-1", "base-2"), "不同 base 行 ID 不应匹配")
    }

    /// 非循环事件（普通 ID）不受归一化影响，行为与修改前一致
    func testAlertSubjectPlainIDsUnchanged() {
        XCTAssertTrue(ReminderAlertService.sameAlertSubject("plain-1", "plain-1"))
        XCTAssertFalse(ReminderAlertService.sameAlertSubject("plain-1", "plain-2"))
    }
}
