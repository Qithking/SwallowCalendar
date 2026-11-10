//
//  RecurrenceSpecTests.swift
//  SwallowCalendarTests
//
//  提醒循环完整对齐：12 预设 / 自定义维度 / 展开与完成推进 / EK 正反向映射
//

import XCTest
import EventKit
import SwiftData
@testable import SwallowCalendar

@MainActor
final class RecurrenceSpecTests: XCTestCase {

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 9) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        return Calendar.current.date(from: comps)!
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: CachedEvent.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func makeCached(start: Date, spec: RecurrenceSpec?, type: RecurrenceType = .custom) -> CachedEvent {
        CachedEvent(
            eventID: UUID().uuidString,
            title: "测试",
            startDate: start,
            endDate: start,
            isAllDay: false,
            calendarID: "cal",
            calendarTitle: "提醒",
            calendarColorHex: "#FF9500",
            isReminder: true,
            recurrenceType: type,
            recurrenceSpecJSON: spec?.jsonString,
            originStartDate: start
        )
    }

    private func expand(_ cached: CachedEvent, from start: Date, days: Int) throws -> [Date] {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(cached)
        let rows: [CachedEvent] = EventCacheService.shared.expandOccurrences(
            of: cached,
            windowStart: start,
            windowEnd: start.addingTimeInterval(TimeInterval(days * 86_400)),
            context: context
        )
        return rows.compactMap { $0.startDate }.sorted()
    }

    // MARK: - 间隔展开

    func testEveryNDaysHonorsInterval() throws {
        let spec = RecurrenceSpec(frequency: .daily, interval: 3)
        let start = date(2030, 1, 1)
        let rows = try expand(makeCached(start: start, spec: spec, type: .daily), from: start, days: 10)
        XCTAssertEqual(rows, [date(2030, 1, 1), date(2030, 1, 4), date(2030, 1, 7), date(2030, 1, 10)])
    }

    func testEveryNWeeklyHonorsInterval() throws {
        let spec = RecurrenceSpec(frequency: .weekly, interval: 3)
        let start = date(2030, 1, 1)
        // 窗口覆盖三期：1/1、1/22、2/12
        let rows = try expand(makeCached(start: start, spec: spec, type: .weekly), from: start, days: 60)
        XCTAssertEqual(rows.prefix(3).map { $0 }, [date(2030, 1, 1), date(2030, 1, 22), date(2030, 2, 12)])
    }

    func testEveryNMonthlyHonorsInterval() throws {
        let spec = RecurrenceSpec(frequency: .monthly, interval: 2, monthDay: 15)
        let start = date(2030, 1, 15)
        let rows = try expand(makeCached(start: start, spec: spec), from: start, days: 160)
        XCTAssertEqual(Array(rows.prefix(3)), [date(2030, 1, 15), date(2030, 3, 15), date(2030, 5, 15)])
    }

    func testEveryNYearlyHonorsInterval() throws {
        let spec = RecurrenceSpec(frequency: .yearly, interval: 2, monthDay: 10, months: [3])
        let start = date(2030, 3, 10)
        let rows = try expand(makeCached(start: start, spec: spec), from: start, days: 5 * 365)
        XCTAssertEqual(Array(rows.prefix(3)), [date(2030, 3, 10), date(2032, 3, 10), date(2034, 3, 10)])
    }

    // MARK: - 工作日 / 周末 / 多选星期

    func testWorkdayStartsAtNextMondayThenSkipsWeekend() throws {
        let spec = RecurrenceSpec(frequency: .weekly, interval: 1, weekdays: [2, 3, 4, 5, 6])
        let start = date(2030, 6, 2)   // 周日
        XCTAssertEqual(spec.firstOccurrence(from: start, isLunar: false), date(2030, 6, 3))
        let rows = try expand(makeCached(start: start, spec: spec, type: .weekly), from: start, days: 9)
        XCTAssertEqual(rows, [date(2030, 6, 3), date(2030, 6, 4), date(2030, 6, 5),
                              date(2030, 6, 6), date(2030, 6, 7), date(2030, 6, 10)])
    }

    func testWeekendKeepsChronologicalOrder() throws {
        let spec = RecurrenceSpec(frequency: .weekly, interval: 1, weekdays: [1, 7])
        let start = date(2030, 6, 7)   // 周五
        let rows = try expand(makeCached(start: start, spec: spec, type: .weekly), from: start, days: 10)
        XCTAssertEqual(Array(rows.prefix(4)), [date(2030, 6, 8), date(2030, 6, 9), date(2030, 6, 15), date(2030, 6, 16)])
    }

    func testWeeklyMultiWeekdaySequence() throws {
        let spec = RecurrenceSpec(frequency: .weekly, interval: 1, weekdays: [2, 4, 6])   // 一、三、五
        let start = date(2030, 6, 5)   // 周三
        XCTAssertEqual(spec.firstOccurrence(from: start, isLunar: false), start)
        let rows = try expand(makeCached(start: start, spec: spec, type: .weekly), from: start, days: 10)
        XCTAssertEqual(Array(rows.prefix(4)), [start, date(2030, 6, 7), date(2030, 6, 10), date(2030, 6, 12)])
    }

    // MARK: - 每月按日期 / 第 N 个周几

    func testMonthlyMissingDateSkipsInsteadOfRounding() throws {
        let spec = RecurrenceSpec(frequency: .monthly, interval: 1, monthDay: 31)
        let start = date(2030, 1, 31)
        let rows = try expand(makeCached(start: start, spec: spec), from: start, days: 150)
        XCTAssertEqual(Array(rows.prefix(3)), [date(2030, 1, 31), date(2030, 3, 31), date(2030, 5, 31)])
    }

    func testMonthlyNthWeekdayAndLast() throws {
        let spec = RecurrenceSpec(frequency: .monthly, interval: 1, nthWeekday: NthWeekday(nth: 2, weekday: 3))
        XCTAssertEqual(spec.occurrence(index: 0, origin: date(2030, 1, 1), isLunar: false), date(2030, 1, 8))
        let last = RecurrenceSpec(frequency: .monthly, interval: 1, nthWeekday: NthWeekday(nth: -1, weekday: 6))
        XCTAssertEqual(last.occurrence(index: 0, origin: date(2030, 1, 1), isLunar: false), date(2030, 1, 25))
    }

    func testYearlyByMonthAndDate() throws {
        let spec = RecurrenceSpec(frequency: .yearly, interval: 1, monthDay: 20, months: [10])
        let start = date(2030, 5, 20)
        XCTAssertEqual(spec.firstOccurrence(from: start, isLunar: false), date(2030, 10, 20))
        XCTAssertEqual(spec.occurrence(index: 1, origin: start, isLunar: false), date(2031, 10, 20))
    }

    // MARK: - 结束重复

    func testEndDateStopsSequence() throws {
        var spec = RecurrenceSpec(frequency: .daily, interval: 1)
        spec.end = .on(date(2030, 1, 10))
        let start = date(2030, 1, 1)
        XCTAssertEqual(spec.next(after: date(2030, 1, 9), origin: start, isLunar: false), date(2030, 1, 10))
        XCTAssertNil(spec.next(after: date(2030, 1, 10), origin: start, isLunar: false))
        let rows = try expand(makeCached(start: start, spec: spec), from: start, days: 20)
        XCTAssertEqual(rows.last, date(2030, 1, 10))
    }

    func testEndCountStopsSequence() throws {
        var spec = RecurrenceSpec(frequency: .daily, interval: 1)
        spec.end = .after(3)
        let start = date(2030, 1, 1)
        XCTAssertEqual(spec.next(after: date(2030, 1, 2), origin: start, isLunar: false), date(2030, 1, 3))
        XCTAssertNil(spec.next(after: date(2030, 1, 3), origin: start, isLunar: false))
    }

    func testEndCountCountsFromShiftedFirstOccurrence() throws {
        // 起始日周日不匹配工作日：首期顺延到周一，次数从首个实际期起算
        var spec = RecurrenceSpec(frequency: .weekly, interval: 1, weekdays: [2, 3, 4, 5, 6])
        spec.end = .after(5)
        let start = date(2030, 6, 2)
        let rows = try expand(makeCached(start: start, spec: spec, type: .weekly), from: start, days: 20)
        XCTAssertEqual(rows, [date(2030, 6, 3), date(2030, 6, 4), date(2030, 6, 5),
                              date(2030, 6, 6), date(2030, 6, 7)])
    }

    func testPreviousOccurrenceSkipsMissingMonth() {
        let spec = RecurrenceSpec(frequency: .monthly, interval: 1, monthDay: 31)
        let origin = date(2030, 1, 31)
        XCTAssertEqual(spec.previous(before: date(2030, 5, 31), origin: origin, isLunar: false), date(2030, 3, 31))
    }

    // MARK: - EK 正向映射

    func testMapperCoversPresets() {
        let anchor = date(2030, 1, 31)
        let workday = RecurrenceSpec(frequency: .weekly, interval: 1, weekdays: [2, 3, 4, 5, 6])
        let rule = RecurrenceEKMapper.rule(for: workday, anchor: anchor, isLunar: false)
        XCTAssertEqual(rule?.frequency, .weekly)
        XCTAssertEqual(rule?.daysOfTheWeek?.count, 5)

        let biweekly = RecurrenceSpec(frequency: .weekly, interval: 2)
        XCTAssertEqual(RecurrenceEKMapper.rule(for: biweekly, anchor: anchor, isLunar: false)?.interval, 2)

        let quarterly = RecurrenceSpec(frequency: .monthly, interval: 3, monthDay: 31)
        XCTAssertEqual(RecurrenceEKMapper.rule(for: quarterly, anchor: anchor, isLunar: false)?.daysOfTheMonth?.first?.intValue, 31)

        let nth = RecurrenceSpec(frequency: .monthly, interval: 1, nthWeekday: NthWeekday(nth: -1, weekday: 6))
        XCTAssertEqual(RecurrenceEKMapper.rule(for: nth, anchor: anchor, isLunar: false)?.setPositions?.first?.intValue, -1)

        var yearly = RecurrenceSpec(frequency: .yearly, interval: 1, monthDay: 31, months: [1])
        yearly.end = .after(5)
        let yearlyRule = RecurrenceEKMapper.rule(for: yearly, anchor: anchor, isLunar: false)
        XCTAssertEqual(yearlyRule?.monthsOfTheYear?.first?.intValue, 1)
        XCTAssertEqual(yearlyRule?.recurrenceEnd?.occurrenceCount, 5)
    }

    func testHourlyAndLunarHaveNoEKRule() {
        XCTAssertNil(RecurrenceEKMapper.rule(
            for: RecurrenceSpec(frequency: .hourly, interval: 1),
            anchor: date(2030, 1, 1), isLunar: false))
        XCTAssertNil(RecurrenceEKMapper.rule(
            for: RecurrenceSpec(frequency: .daily, interval: 1),
            anchor: date(2030, 1, 1), isLunar: true))
    }

    // MARK: - EK 反向映射

    func testReverseMapperRestoresIntervalAndWeekdays() {
        let rule = EKRecurrenceRule(
            recurrenceWith: .weekly,
            interval: 2,
            daysOfTheWeek: [
                EKRecurrenceDayOfWeek(dayOfTheWeek: .monday, weekNumber: 0),
                EKRecurrenceDayOfWeek(dayOfTheWeek: .wednesday, weekNumber: 0)
            ],
            daysOfTheMonth: nil,
            monthsOfTheYear: nil,
            weeksOfTheYear: nil,
            daysOfTheYear: nil,
            setPositions: nil,
            end: nil
        )
        let spec = RecurrenceEKMapper.spec(from: rule, anchor: date(2030, 1, 1), inferredType: .weekly)
        XCTAssertTrue(spec?.frequency == .weekly)
        XCTAssertEqual(spec?.interval, 2)
        XCTAssertEqual(spec?.weekdays, [2, 4])
    }

    func testReverseMapperRestoresEndCountAndMonths() {
        let rule = EKRecurrenceRule(
            recurrenceWith: .yearly,
            interval: 1,
            daysOfTheWeek: nil,
            daysOfTheMonth: [NSNumber(value: 15)],
            monthsOfTheYear: [NSNumber(value: 6)],
            weeksOfTheYear: nil,
            daysOfTheYear: nil,
            setPositions: nil,
            end: EKRecurrenceEnd(occurrenceCount: 4)
        )
        let spec = RecurrenceEKMapper.spec(from: rule, anchor: date(2030, 1, 1), inferredType: .yearly)
        XCTAssertEqual(spec?.months, [6])
        XCTAssertEqual(spec?.monthDay, 15)
        XCTAssertEqual(spec?.end.mode, .count)
        XCTAssertEqual(spec?.end.count, 4)
    }

    // MARK: - 外部变更回流 / 幂等

    func testMergeAdoptsExternalIntervalChange() {
        let existing = makeCached(
            start: date(2030, 1, 1),
            spec: RecurrenceSpec(frequency: .weekly, interval: 1),
            type: .weekly
        )
        let ek = makeEvent(spec: RecurrenceSpec(frequency: .weekly, interval: 2), type: .weekly, notes: nil)
        XCTAssertTrue(EventCacheService.mergeReminderUpdate(existing: existing, ek: ek))
        XCTAssertEqual(existing.recurrenceSpec?.interval, 2)
    }

    func testMergeClearsWhenExternalRemovesRuleWithoutMarker() {
        let existing = makeCached(start: date(2030, 1, 1), spec: RecurrenceSpec(frequency: .daily, interval: 1), type: .daily)
        let ek = makeEvent(spec: nil, type: .none, notes: nil)
        XCTAssertTrue(EventCacheService.mergeReminderUpdate(existing: existing, ek: ek))
        XCTAssertEqual(existing.recurrenceType, .none)
        XCTAssertNil(existing.recurrenceSpecJSON)
    }

    func testMergeKeepsLocalOnlyHourlyWhenMarkerPresent() {
        let existing = makeCached(start: date(2030, 1, 1), spec: RecurrenceSpec(frequency: .hourly, interval: 1), type: .hourly)
        let ek = makeEvent(spec: nil, type: .none, notes: EventCacheService.localRecurrenceMarker)
        XCTAssertFalse(EventCacheService.mergeReminderUpdate(existing: existing, ek: ek))
        XCTAssertEqual(existing.recurrenceType, .hourly)
        XCTAssertTrue(existing.recurrenceSpec?.frequency == .hourly)
    }

    func testMergeKeepsLunarSpecWhenMarkerPresent() {
        // 系统侧读回本体提醒（无 EK 规则 + 本地标记）时，不得把农历规则降级/清空
        let spec = RecurrenceSpec(frequency: .monthly, interval: 1, monthDay: 15)
        let existing = makeCached(start: date(2030, 1, 1), spec: spec, type: .monthly)
        existing.isLunar = true
        let ek = makeEvent(spec: nil, type: .none, notes: EventCacheService.localRecurrenceMarker)
        XCTAssertFalse(EventCacheService.mergeReminderUpdate(existing: existing, ek: ek))
        XCTAssertEqual(existing.recurrenceSpec, spec)
        XCTAssertTrue(existing.isLunar)
        XCTAssertTrue(existing.isRecurringActive)
    }

    func testMirrorKeyFieldsNormalizeAndClear() {
        let cached = makeCached(start: date(2030, 1, 1), spec: RecurrenceSpec(frequency: .daily), type: .daily)
        cached.mirrorKeys = ["b", "a", "a"]
        XCTAssertEqual(cached.mirrorKeys, ["a", "b"])
        cached.suppressedMirrorKeys = ["k2", "k1", "k1"]
        XCTAssertEqual(cached.suppressedMirrorKeys, ["k1", "k2"])

        // 应用内改规则/重新勾选农历时清空抑制
        cached.suppressedMirrorKeys = []
        XCTAssertNil(cached.suppressedMirrorKeysJSON)
    }

    func testSpecJSONRoundTripIsStable() {
        let spec = RecurrenceSpec(frequency: .monthly, interval: 3, nthWeekday: NthWeekday(nth: -1, weekday: 6), end: .after(8))
        let encoded = spec.jsonString
        XCTAssertEqual(RecurrenceSpec.decode(encoded), spec)
        XCTAssertTrue(RecurrenceSpec.jsonEquals(encoded, spec.jsonString))
        XCTAssertFalse(RecurrenceSpec.jsonEquals(encoded, RecurrenceSpec(frequency: .monthly).jsonString))
    }

    /// 体检 P1-2：缺键容错——Codable 合成不采用属性默认值，未来新增字段时
    /// 存量 JSON 缺新键必须回落默认值而非整体解码失败（向前兼容）
    func testSpecJSONDecodeToleratesMissingKeys() {
        // 仅 frequency 单键（未来加字段后旧 JSON 的形态）：可选键全回落默认值
        let minimal = RecurrenceSpec.decode(#"{"frequency":"weekly"}"#)
        XCTAssertEqual(minimal, RecurrenceSpec(frequency: .weekly))
        // 缺 end 键
        let noEnd = RecurrenceSpec.decode(#"{"frequency":"daily","interval":2}"#)
        XCTAssertEqual(noEnd, RecurrenceSpec(frequency: .daily, interval: 2))
        // end 内部缺 mode 视为 .never 并忽略矛盾载荷（mode 是唯一判别式，不产生不一致中间态）
        let noMode = RecurrenceSpec.decode(#"{"frequency":"daily","end":{"count":5}}"#)
        XCTAssertEqual(noMode, RecurrenceSpec(frequency: .daily))
        // 真损坏（非法 JSON）仍判失败，不因容错而吞掉
        XCTAssertNil(RecurrenceSpec.decode("{broken"))
        // 未知 frequency 无可靠猜测，仍判失败
        XCTAssertNil(RecurrenceSpec.decode(#"{"frequency":"quarterly"}"#))
    }

    /// 用户口径：新建/编辑选「自定义」且无既有规则时，频率底稿默认每小时
    ///（customDraft 为自定义底稿唯一真源，新建/编辑/批量共用）
    func testCustomDraftDefaultsToHourly() {
        XCTAssertEqual(RecurrenceSpec.customDraft, RecurrenceSpec(frequency: .hourly, interval: 1))
        // spec(for: .custom) 无既有规则时兜底到同一底稿；有则保留现有维度（语义不变）
        let fallback = RecurrenceSpec.spec(for: .custom, anchor: date(2030, 1, 1), current: nil)
        XCTAssertEqual(fallback?.frequency, .hourly)
        XCTAssertEqual(fallback?.interval, 1)
        let kept = RecurrenceSpec(frequency: .weekly, weekdays: [2])
        XCTAssertEqual(RecurrenceSpec.spec(for: .custom, anchor: date(2030, 1, 1), current: kept), kept)
    }

    // MARK: - Helpers

    private func makeEvent(spec: RecurrenceSpec?, type: RecurrenceType, notes: String?) -> CalendarEvent {
        CalendarEvent(
            id: "ek",
            title: "测试",
            startDate: date(2030, 1, 1),
            endDate: date(2030, 1, 1),
            isAllDay: false,
            calendarID: "cal",
            calendarTitle: "提醒",
            calendarColorHex: "#FF9500",
            category: .user,
            isCompleted: false,
            priority: 0,
            isReminder: true,
            recurrenceType: type,
            recurrenceSpec: spec,
            reminderMinutes: 0,
            eventColorHex: nil,
            notes: notes
        )
    }
}
