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
//  - 防双份：.hourly 归入无推进组（不虚拟展开、不参与完成推进）

import XCTest
import EventKit
@testable import SwallowCalendar

final class EKRecurrenceSyncTests: XCTestCase {

    /// 当日零点 + hour 小时（构造整点历史到期序列）
    private func date(_ hour: Int) -> Date {
        Calendar.current.startOfDay(for: Date()).addingTimeInterval(TimeInterval(hour) * 3600)
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

    // MARK: - 防双份：.hourly 不参与虚拟展开与推进

    func testHourlyNextOccurrenceIsNil() {
        let now = Date()
        XCTAssertNil(CalendarService.nextOccurrence(after: now, recurrenceType: .hourly, isLunar: false))
        XCTAssertNil(CalendarService.nextOccurrence(after: now, recurrenceType: .hourly, isLunar: true))
    }

    func testHourlyPreviousOccurrenceIsNil() {
        let now = Date()
        XCTAssertNil(CalendarService.previousOccurrence(before: now, recurrenceType: .hourly, isLunar: false))
    }
}
