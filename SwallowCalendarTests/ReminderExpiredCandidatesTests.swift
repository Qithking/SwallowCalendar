//
//  ReminderExpiredCandidatesTests.swift
//  SwallowCalendarTests
//
//  bug: startup-expired-popup-recurring-miss
//  启动过期弹窗候选：循环 base 行须展开为 occurrence 实例（与主面板同源），
//  被游标越过的未完成历史实例不得漏报；已完成历史实例不进候选
//
//  日期锚点：2026-10-26 周一、10-27 周二、10-28 周三、10-29 周四
//

import XCTest
import SwiftData
@testable import SwallowCalendar

@MainActor
final class ReminderExpiredCandidatesTests: XCTestCase {

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
        originStartDate: Date? = nil,
        isCompleted: Bool = false
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
        event.isCompleted = isCompleted
        context.insert(event)
        try context.save()
        return event
    }

    // MARK: - 过期候选集

    /// 核心 bug：游标越过今日未完成实例（如完成后撤销/创建推进）时，
    /// 启动过期候选须包含今日实例——与主面板展开链路同源，不得漏报
    func testExpiredCandidatesIncludeCursorSkippedUncompletedOccurrence() throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        let context = container.mainContext
        // 早上上班：daily 09:00，锚点 10/27，游标已推进到 10/29，10/28 未完成
        try insertEvent(
            into: context,
            eventID: "base-morning",
            title: "早上上班",
            startDate: date(2026, 10, 29, 9, 0),
            recurrenceType: .daily,
            originStartDate: date(2026, 10, 27, 9, 0)
        )
        // 起床：普通单次已过期（直查主表本就能命中）
        try insertEvent(
            into: context,
            eventID: "single-wake",
            title: "起床",
            startDate: date(2026, 10, 28, 8, 0)
        )

        let now = date(2026, 10, 28, 14, 0)
        let upperBound = now.addingTimeInterval(1440 * 60)
        // 模拟 checkDueEvents 原始粗筛结果：两行均落 startDate 窗口内
        let raw: [CachedEvent] = try context.fetch(FetchDescriptor<CachedEvent>())
        XCTAssertEqual(Set(raw.map(\.eventID)), ["base-morning", "single-wake"])

        let candidates = ReminderAlertService.expiredCheckCandidates(
            rawEvents: raw,
            upperBound: upperBound,
            context: context
        )

        // 关键断言：今日 09:00 未完成实例进入候选（修复前漏报）
        let todayOcc = candidates.first {
            CachedEvent.parseOccurrenceID($0.eventID)?.occurrence == date(2026, 10, 28, 9, 0)
        }
        XCTAssertNotNil(todayOcc, "被游标越过的今日未完成实例应进入过期候选")
        XCTAssertEqual(todayOcc?.title, "早上上班")
        XCTAssertEqual(todayOcc?.isCompleted, false)

        // 普通单次行原样保留
        XCTAssertTrue(candidates.contains { $0.eventID == "single-wake" })
        // base 行被展开实例替换，不再以裸 baseID 出现（避免游标实例重复弹）
        XCTAssertFalse(candidates.contains { $0.eventID == "base-morning" })
        // 游标实例（10/29 09:00）在候选中，供后续 alertTime 级别判定
        XCTAssertTrue(candidates.contains {
            CachedEvent.parseOccurrenceID($0.eventID)?.occurrence == date(2026, 10, 29, 9, 0)
        })
        // 候选不含已完成行（完成历史实例不弹窗）
        XCTAssertFalse(candidates.contains { $0.isCompleted }, "已完成实例不应进入过期候选")
    }

    /// 完成历史实例（如今日已完成推进到明日）被剔除，更早未完成实例仍保留
    func testExpiredCandidatesExcludeCompletedHistoryOccurrence() throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        let context = container.mainContext
        // 锚点 10/26，10/28 已完成推进到 10/29；10/26、10/27 未完成
        try insertEvent(
            into: context,
            eventID: "base-b",
            title: "早上下班休息",
            startDate: date(2026, 10, 29, 12, 0),
            recurrenceType: .daily,
            completed: [date(2026, 10, 28, 12, 0)],
            originStartDate: date(2026, 10, 26, 12, 0)
        )

        let upperBound = date(2026, 10, 28, 14, 0).addingTimeInterval(1440 * 60)
        let raw: [CachedEvent] = try context.fetch(FetchDescriptor<CachedEvent>())
        let candidates = ReminderAlertService.expiredCheckCandidates(
            rawEvents: raw,
            upperBound: upperBound,
            context: context
        )

        let occurrences = candidates.compactMap { CachedEvent.parseOccurrenceID($0.eventID)?.occurrence }
        XCTAssertFalse(occurrences.contains(date(2026, 10, 28, 12, 0)), "已完成历史实例不应进入候选")
        XCTAssertTrue(occurrences.contains(date(2026, 10, 27, 12, 0)), "未完成历史实例应保留")
        XCTAssertFalse(candidates.contains { $0.isCompleted })
    }

    /// 真实库数据形态（bug 第二轮）：旧版本完成操作把 base 行置 isCompleted=1
    /// 且未写完成历史、未推进游标——循环行候选资格不得看 base.isCompleted
    /// （主面板 expandOccurrences 也不看），否则弹窗漏报与主面板不符
    func testExpiredCandidatesIncludeCompletedBaseRowWithUncompletedOccurrences() throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        let context = container.mainContext
        // 复刻「早上上班」：游标停 10/28 09:00、origin 10/24、base 已完成、完成历史空
        try insertEvent(
            into: context,
            eventID: "base-done",
            title: "早上上班",
            startDate: date(2026, 10, 28, 9, 0),
            recurrenceType: .daily,
            originStartDate: date(2026, 10, 24, 9, 0),
            isCompleted: true
        )

        let now = date(2026, 10, 28, 14, 0)
        let upperBound = now.addingTimeInterval(1440 * 60)
        // 模拟弹窗粗筛结果：base 行因 isCompleted=1 被 fetch 谓词滤掉（rawEvents 为空）
        let raw: [CachedEvent] = try context.fetch(FetchDescriptor<CachedEvent>(
            predicate: #Predicate { !$0.isCompleted }
        ))
        XCTAssertTrue(raw.isEmpty, "粗筛滤掉已完成 base 行（复刻应用真实 fetch 结果）")

        let candidates = ReminderAlertService.expiredCheckCandidates(
            rawEvents: raw,
            upperBound: upperBound,
            context: context
        )

        // 展开实例（10/24~10/28 09:00）进入候选——判定标准是实例 isCompleted=false
        for day in [24, 25, 26, 27, 28] {
            XCTAssertTrue(
                candidates.contains {
                    CachedEvent.parseOccurrenceID($0.eventID)?.occurrence == date(2026, 10, day, 9, 0)
                },
                "10/\(day) 09:00 未完成实例应进入过期候选"
            )
        }
        XCTAssertFalse(candidates.contains { $0.isCompleted }, "候选不含已完成实例")
    }

    // MARK: - 复合 ID 展示实例解析（弹窗 snooze 路径）
    /// 未完成 occurrence 复合 ID 解析为展示实例；已完成 occurrence 返回 nil（记录 GC）
    func testDisplayOccurrenceResolvesCompositeID() throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        let context = container.mainContext
        try insertEvent(
            into: context,
            eventID: "base-x",
            title: "早上上班",
            startDate: date(2026, 10, 29, 9, 0),
            recurrenceType: .daily,
            completed: [date(2026, 10, 28, 9, 0)],
            originStartDate: date(2026, 10, 27, 9, 0)
        )

        // 未完成实例：可解析，字段与 occurrence 一致
        let unresolvedID = CachedEvent.makeOccurrenceID(baseID: "base-x", occurrence: date(2026, 10, 27, 9, 0))
        let instance = EventCacheService.shared.displayOccurrence(withID: unresolvedID, context: context)
        XCTAssertEqual(instance?.eventID, unresolvedID)
        XCTAssertEqual(instance?.title, "早上上班")
        XCTAssertEqual(instance?.startDate, date(2026, 10, 27, 9, 0))
        XCTAssertEqual(instance?.isCompleted, false)

        // 已完成实例：返回 nil（snooze 记录按失效 GC）
        let completedID = CachedEvent.makeOccurrenceID(baseID: "base-x", occurrence: date(2026, 10, 28, 9, 0))
        XCTAssertNil(EventCacheService.shared.displayOccurrence(withID: completedID, context: context))

        // 普通 eventID（无复合标记）：返回 nil，走原直查路径
        XCTAssertNil(EventCacheService.shared.displayOccurrence(withID: "base-x", context: context))
    }

    // MARK: - 弹窗完成动作与主面板一致性

    /// 需求：弹窗完成循环实例后主面板待办消失——完成走 toggleEventCompleted 同一入口
    ///（与主界面 TodayTodoPopoverView 相同），occurrence 写完成历史，主面板展开
    /// 判定 isCompleted 后归「已完成」组。复刻库中「早上上班」真实行状态：
    /// base isCompleted=1、完成历史空、游标停 10/28、origin 10/24
    func testPopupCompletionRemovesOccurrenceFromMainPanelTodo() async throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        let context = container.mainContext
        let base = try insertEvent(
            into: context,
            eventID: "base-sync",
            title: "早上上班",
            startDate: date(2026, 10, 28, 9, 0),
            recurrenceType: .daily,
            originStartDate: date(2026, 10, 24, 9, 0),
            isCompleted: true
        )

        // 弹窗候选中的今日实例复合 ID（markAsCompleted 实际传入的 ID 形态）
        let todayID = CachedEvent.makeOccurrenceID(baseID: "base-sync", occurrence: date(2026, 10, 28, 9, 0))
        let candidates = ReminderAlertService.expiredCheckCandidates(
            rawEvents: [],
            upperBound: date(2026, 10, 28, 14, 0).addingTimeInterval(1440 * 60),
            context: context
        )
        XCTAssertTrue(candidates.contains { $0.eventID == todayID }, "前置：今日实例在弹窗候选中")

        // 弹窗「单条完成」→ 与主界面同一完成入口（复合 ID 分流 occurrence 级完成）
        await calendarService.toggleEventCompleted(eventID: todayID, isCompleted: true, isReminder: base.isReminder)

        // 完成历史写入 + 游标推进（今日实例 = 游标实例，应推进到 10/29）
        XCTAssertTrue(base.completedOccurrenceDates.contains(date(2026, 10, 28, 9, 0)), "完成历史应含今日实例")
        XCTAssertEqual(base.startDate, date(2026, 10, 29, 9, 0), "游标实例完成后应推进到下一期")

        // 主面板判定：expandOccurrences 不再产出该日期的未完成实例
        let after = EventCacheService.shared.expandOccurrences(
            of: base,
            windowStart: date(2026, 10, 28, 0, 0),
            windowEnd: date(2026, 10, 29, 0, 0),
            context: context
        )
        let todoOccurrence = after.first {
            !$0.isCompleted && $0.startDate == date(2026, 10, 28, 9, 0)
        }
        XCTAssertNil(todoOccurrence, "完成后主面板待办不应再出现该实例")
        XCTAssertTrue(after.contains { $0.isCompleted && $0.startDate == date(2026, 10, 28, 9, 0) }, "应归入已完成历史行")
    }

    /// 历史未完成实例补完成：只记完成历史，游标不回退（序列推进事实不可逆）
    func testPopupCompletionOfHistoricalOccurrenceKeepsCursor() async throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        let context = container.mainContext
        let base = try insertEvent(
            into: context,
            eventID: "base-hist",
            title: "早上上班",
            startDate: date(2026, 10, 28, 9, 0),
            recurrenceType: .daily,
            originStartDate: date(2026, 10, 24, 9, 0),
            isCompleted: true
        )

        let histID = CachedEvent.makeOccurrenceID(baseID: "base-hist", occurrence: date(2026, 10, 24, 9, 0))
        await calendarService.toggleEventCompleted(eventID: histID, isCompleted: true, isReminder: base.isReminder)

        XCTAssertTrue(base.completedOccurrenceDates.contains(date(2026, 10, 24, 9, 0)), "历史实例完成只记历史")
        XCTAssertEqual(base.startDate, date(2026, 10, 28, 9, 0), "游标不因历史补完成而变化")
    }

    // MARK: - 过期时间排序键

    /// 弹窗降序排序键语义：过期时刻 = startDate − 最大提醒提前量；
    /// 未设提醒即 startDate 本身；startDate 缺失为 nil
    func testExpiryTimeSemantics() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let start = date(2026, 10, 28, 9, 0)
        let withReminder = try insertEvent(into: context, eventID: "e-rem", title: "有提醒", startDate: start)
        withReminder.reminderOffsets = [10, 30]
        XCTAssertEqual(withReminder.expiryTime, date(2026, 10, 28, 8, 30), "过期时刻取最早触发的 alertTime")

        let noReminder = try insertEvent(into: context, eventID: "e-norem", title: "无提醒", startDate: start)
        XCTAssertEqual(noReminder.expiryTime, start, "未设提醒时过期时刻即开始时间")

        let undated = try insertEvent(into: context, eventID: "e-undated", title: "无日期", startDate: nil)
        XCTAssertNil(undated.expiryTime)
    }

    // MARK: - 弹窗显示期间外部变更同步（4 视图同步）

    /// 过期弹窗快照与外部变更同步：别处完成后重查，已完成/已删除行移除，
    /// 未完成行刷新为最新字段（编辑后的标题/时间同步显示）
    func testRefreshedDisplayRowsRemovesCompletedAndDeletedRows() throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        let context = container.mainContext
        // occurrence 展示实例（base 复刻「早上上班」）
        try insertEvent(
            into: context,
            eventID: "base-r",
            title: "早上上班",
            startDate: date(2026, 10, 28, 9, 0),
            recurrenceType: .daily,
            originStartDate: date(2026, 10, 24, 9, 0)
        )
        let occID = CachedEvent.makeOccurrenceID(baseID: "base-r", occurrence: date(2026, 10, 28, 9, 0))
        // 普通未完成行 / 普通已完成行 / 已删除行
        try insertEvent(into: context, eventID: "e-fresh", title: "未完成", startDate: date(2026, 10, 28, 8, 0))
        try insertEvent(into: context, eventID: "e-done", title: "已办", startDate: date(2026, 10, 28, 7, 0), isCompleted: true)

        let snapshot = [occID, "e-fresh", "e-done", "e-deleted"].map { id in
            CachedEvent(eventID: id, title: "旧快照", startDate: date(2026, 10, 28, 0, 0), endDate: nil,
                        isAllDay: false, calendarID: "t", calendarTitle: "t", calendarColorHex: "#000")
        }

        let refreshed = ReminderAlertService.refreshedDisplayRows(events: snapshot, context: context)

        let ids = refreshed.map(\.eventID)
        XCTAssertTrue(ids.contains(occID), "未完成 occurrence 实例保留")
        XCTAssertTrue(ids.contains("e-fresh"), "未完成普通行保留")
        XCTAssertFalse(ids.contains("e-done"), "别处已完成的行移除")
        XCTAssertFalse(ids.contains("e-deleted"), "已删除的行移除")
        // 保留行刷新为最新数据（不再是旧快照字段）
        XCTAssertEqual(refreshed.first { $0.eventID == "e-fresh" }?.title, "未完成")
        XCTAssertEqual(refreshed.first { $0.eventID == occID }?.title, "早上上班")
    }
}
