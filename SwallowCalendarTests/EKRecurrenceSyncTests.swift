//
//  EKRecurrenceSyncTests.swift
//  SwallowCalendarTests
//
//  bug: ek-recurrence-materialization-mirror
//  根因：Apple 对循环提醒按「发生」物化为独立 EKReminder（历史发生以已完成态落库，
//  仅未完成锚条目带 recurrenceRules），且 EK 公开 API 无 hourly 表达（每小时与每天
//  均为 daily/interval=1）。映射硬编码 .none 导致系统侧「每小时」同步后显示「1次」，
//  物化历史全量入库导致多条同名提醒。
//
//  修复语义（锚条目法 + 间隔推断）：
//  - 过滤：已完成 && title ∈ 锚集合（带规则未完成条目）→ 物化历史，不入库
//  - 映射：无规则 → .none；weekly/monthly/yearly 直接映射；
//          daily 歧义按同 title 已完成历史到期间隔众数推断（1h → .hourly，否则 .daily）
//
//  bug: hourly-recurrence-invisible-in-lists——.hourly 曾归入无推进组（不展开不推进），
//  完成历史把游标「跳过」后 nextOccurrence=nil 直接断链，待办/已办列表当天 0 行；
//  修复后 .hourly 与每天/每周同语义：逐小时虚拟展开 + 完成推进 +1h（锚条目法已
//  过滤 Apple 物化的已完成历史，恢复展开无双份风险）

import XCTest
import EventKit
import SwiftData
@testable import SwallowCalendar

@MainActor
final class EKRecurrenceSyncTests: XCTestCase {

    /// 当日零点 + hour 小时（构造整点历史到期序列）
    private func date(_ hour: Int) -> Date {
        Calendar.current.startOfDay(for: Date()).addingTimeInterval(TimeInterval(hour) * 3600)
    }

    /// 显式日期构造（本地时区）
    private func makeDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        return Calendar.current.date(from: comps)!
    }

    /// 仅注册 CachedEvent 的内存 SwiftData 容器（expandOccurrences 休日检查所需）
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: CachedEvent.self, configurations: config)
    }

    // MARK: - 规则映射：无规则 → 1次

    func testMapRecurrenceRuleNilToNone() {
        XCTAssertEqual(CalendarService.mapRecurrenceRule(nil, historyDueDates: []), .none)
    }

    // MARK: - 规则映射：daily 歧义（每小时/每天在 EK 层同表达）

    func testMapRecurrenceRuleDailyWithoutHistoryFallsBackToDaily() {
        let rule = EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)
        XCTAssertEqual(CalendarService.mapRecurrenceRule(rule, historyDueDates: []), .daily)
    }

    func testMapRecurrenceRuleDailyWithHourlyHistoryInfersHourly() {
        let rule = EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)
        let history = [date(16), date(17), date(18), date(19), date(20), date(21)]
        XCTAssertEqual(CalendarService.mapRecurrenceRule(rule, historyDueDates: history), .hourly)
    }

    func testMapRecurrenceRuleDailyWithDailyHistoryStaysDaily() {
        let rule = EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)
        let history = [date(16), date(40)]  // 相邻间隔 1 天
        XCTAssertEqual(CalendarService.mapRecurrenceRule(rule, historyDueDates: history), .daily)
    }

    // MARK: - 规则映射：周/月/年直接映射

    func testMapRecurrenceRuleWeeklyMonthlyYearly() {
        let weekly = EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil)
        let monthly = EKRecurrenceRule(recurrenceWith: .monthly, interval: 1, end: nil)
        let yearly = EKRecurrenceRule(recurrenceWith: .yearly, interval: 1, end: nil)
        XCTAssertEqual(CalendarService.mapRecurrenceRule(weekly, historyDueDates: []), .weekly)
        XCTAssertEqual(CalendarService.mapRecurrenceRule(monthly, historyDueDates: []), .monthly)
        XCTAssertEqual(CalendarService.mapRecurrenceRule(yearly, historyDueDates: []), .yearly)
    }

    // MARK: - 物化历史过滤（锚条目法）

    func testMaterializedHistorySkippedWhenCompletedAndAnchored() {
        let anchors = Set(["测试提醒"])
        XCTAssertTrue(CalendarService.isMaterializedHistory(isCompleted: true, title: "测试提醒", anchorTitles: anchors))
    }

    func testUncompletedOccurrenceKept() {
        let anchors = Set(["测试提醒"])
        XCTAssertFalse(CalendarService.isMaterializedHistory(isCompleted: false, title: "测试提醒", anchorTitles: anchors))
    }

    func testCompletedWithoutAnchorKept() {
        let anchors = Set(["测试提醒"])
        XCTAssertFalse(CalendarService.isMaterializedHistory(isCompleted: true, title: "买牛奶", anchorTitles: anchors))
    }

    func testCompletedWithEmptyAnchorsKept() {
        XCTAssertFalse(CalendarService.isMaterializedHistory(isCompleted: true, title: "测试提醒", anchorTitles: []))
    }

    // MARK: - bug: hourly-recurrence-invisible-in-lists（hourly 恢复展开+推进）

    func testHourlyNextOccurrenceAdvancesOneHour() {
        let now = Date()
        let next = CalendarService.nextOccurrence(after: now, recurrenceType: .hourly, isLunar: false)
        XCTAssertEqual(next?.timeIntervalSince1970 ?? 0,
                       now.addingTimeInterval(3600).timeIntervalSince1970, accuracy: 0.001)
        // 农历分支同语义（小时加法不涉农历相位）
        let lunarNext = CalendarService.nextOccurrence(after: now, recurrenceType: .hourly, isLunar: true)
        XCTAssertEqual(lunarNext?.timeIntervalSince1970 ?? 0,
                       now.addingTimeInterval(3600).timeIntervalSince1970, accuracy: 0.001)
    }

    func testHourlyPreviousOccurrenceStepsBackOneHour() {
        let now = Date()
        let prev = CalendarService.previousOccurrence(before: now, recurrenceType: .hourly, isLunar: false)
        XCTAssertEqual(prev?.timeIntervalSince1970 ?? 0,
                       now.addingTimeInterval(-3600).timeIntervalSince1970, accuracy: 0.001)
    }

    /// 展开起点对齐：hourly 走小时整除跳转（与 nextOccurrence 的 .hour 加法同源）
    func testHourlyAlignedExpansionStartAlignsToHourPhase() {
        // 锚点 10-28 09:00，窗口 10-29 14:30 → 整除相位 14:00（+29h）
        let aligned = CalendarService.alignedExpansionStart(
            origin: makeDate(2026, 10, 28, 9),
            recurrenceType: .hourly, isLunar: false,
            windowStart: makeDate(2026, 10, 29, 14, 30)
        )
        XCTAssertEqual(aligned, makeDate(2026, 10, 29, 14))
    }

    /// 复刻缓存实况：游标冻结在昨日 23:00，前两小时已完成——
    /// 今天窗口必须恢复 00:00-23:00 每小时展开（修复前 0 行）
    func testHourlyExpansionRecoversAfterCompletedCursor() throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let cursor = today.addingTimeInterval(-3600)      // 昨日 23:00（冻结游标）
        let event = CachedEvent(
            eventID: "hourly-base",
            title: "测试提醒",
            startDate: cursor,
            endDate: cursor,
            isAllDay: false,
            calendarID: "reminder",
            calendarTitle: "提醒事项",
            calendarColorHex: "#FF0000",
            recurrenceType: .hourly
        )
        event.isReminder = true
        event.completedOccurrenceDates = [
            today.addingTimeInterval(-2 * 3600),  // 昨日 22:00
            cursor                                 // 昨日 23:00
        ]

        let windowEnd = calendar.date(byAdding: .day, value: 1, to: today)!
        let instances = EventCacheService.shared.expandOccurrences(
            of: event, windowStart: today, windowEnd: windowEnd,
            context: container.mainContext
        )

        // 今天 00:00-23:00 每小时一行，全部未完成
        XCTAssertEqual(instances.count, 24, "今天窗口应展开 24 个每小时实例，实际 \(instances.count) 行")
        let starts = instances.map { $0.startDate ?? .distantPast }.sorted()
        if let first = starts.first {
            XCTAssertEqual(first.timeIntervalSince1970, today.timeIntervalSince1970, accuracy: 0.001)
        }
        if let last = starts.last {
            XCTAssertEqual(last.timeIntervalSince1970,
                           today.addingTimeInterval(23 * 3600).timeIntervalSince1970, accuracy: 0.001)
        }
        XCTAssertTrue(instances.allSatisfy { !$0.isCompleted })
    }
}
