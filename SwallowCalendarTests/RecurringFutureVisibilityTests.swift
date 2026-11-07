//
//  RecurringFutureVisibilityTests.swift
//  SwallowCalendarTests
//
//  回归：A 循环任务未来实例在月历/列表/调度链路可见；B 转单次后未来 0 行、历史期次可见
//  口径来源：用户 2026-11-07 验收要求（A/B 同一判定入口互斥成立）
//

import XCTest
import SwiftData
@testable import SwallowCalendar

@MainActor
final class RecurringFutureVisibilityTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 9) -> Date {
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d; comps.hour = h
        return Calendar.current.date(from: comps)!
    }

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: CachedEvent.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = container.mainContext
        EventCacheService.shared.configure(with: container)
    }

    override func tearDownWithError() throws {
        container = nil
        context = nil
    }

    private func expanded(
        of event: CachedEvent,
        from start: Date,
        to end: Date
    ) -> [CachedEvent] {
        EventCacheService.shared.expandOccurrences(
            of: event, windowStart: start, windowEnd: end, context: context
        )
    }

    private func days(_ rows: [CachedEvent]) -> [Int] {
        rows.compactMap(\.startDate).map { Calendar.current.component(.day, from: $0) }
    }

    // MARK: - A1. 12 项预设：未来实例逐项断言

    func testAllPresetsProduceFutureInstances() throws {
        let anchor = date(2026, 11, 6)  // 周五
        let december = (date(2026, 12, 1, 0), date(2027, 1, 1, 0))
        let wide = (date(2026, 11, 1, 0), date(2028, 1, 1, 0))

        // 每天
        let daily = RecurrenceSpec.spec(for: .daily, anchor: anchor)!
        let dailyRows = expanded(of: makeEvent(id: "p-daily", start: anchor, spec: daily), from: december.0, to: december.1)
        XCTAssertEqual(dailyRows.count, 31, "每天：12 月应 31 期，实际 \(days(dailyRows))")
        XCTAssertEqual(days(dailyRows).first, 1)
        XCTAssertEqual(days(dailyRows).last, 31)

        // 工作日
        let workday = RecurrenceSpec.spec(for: .workday, anchor: anchor)!
        let workdayRows = expanded(of: makeEvent(id: "p-workday", start: anchor, spec: workday), from: december.0, to: december.1)
        XCTAssertEqual(workdayRows.count, 23, "工作日：12 月应 23 期，实际 \(days(workdayRows))")
        for row in workdayRows {
            let weekday = Calendar.current.component(.weekday, from: row.startDate!)
            XCTAssertTrue((2...6).contains(weekday), "工作日产出了周末实例: \(row.startDate!)")
        }

        // 周末
        let weekend = RecurrenceSpec.spec(for: .weekend, anchor: anchor)!
        let weekendRows = expanded(of: makeEvent(id: "p-weekend", start: anchor, spec: weekend), from: december.0, to: december.1)
        XCTAssertEqual(weekendRows.count, 8, "周末：12 月应 8 期，实际 \(days(weekendRows))")
        for row in weekendRows {
            let weekday = Calendar.current.component(.weekday, from: row.startDate!)
            XCTAssertTrue([1, 7].contains(weekday), "周末产出了工作日实例: \(row.startDate!)")
        }

        // 每周（锚点周五）
        let weekly = RecurrenceSpec.spec(for: .weekly, anchor: anchor)!
        XCTAssertEqual(
            days(expanded(of: makeEvent(id: "p-weekly", start: anchor, spec: weekly), from: december.0, to: december.1)),
            [4, 11, 18, 25],
            "每周：应为 12 月全部周五"
        )

        // 每两周（锚点周五，14 天间隔）
        let biweekly = RecurrenceSpec.spec(for: .biweekly, anchor: anchor)!
        XCTAssertEqual(
            days(expanded(of: makeEvent(id: "p-biweekly", start: anchor, spec: biweekly), from: december.0, to: december.1)),
            [4, 18],
            "每两周：12 月应 2 期且间隔 14 天"
        )

        // 每月（锚点日 6）
        let monthly = RecurrenceSpec.spec(for: .monthly, anchor: anchor)!
        XCTAssertEqual(
            days(expanded(of: makeEvent(id: "p-monthly", start: anchor, spec: monthly), from: december.0, to: december.1)),
            [6],
            "每月：12 月应 1 期"
        )

        // 每 3 个月
        let quarterly = RecurrenceSpec.spec(for: .quarterly, anchor: anchor)!
        let quarterDates = expanded(
            of: makeEvent(id: "p-quarterly", start: anchor, spec: quarterly),
            from: date(2026, 11, 1, 0), to: date(2027, 3, 1, 0)
        ).compactMap(\.startDate).sorted()
        XCTAssertEqual(quarterDates, [date(2026, 11, 6), date(2027, 2, 6)], "每3个月：11 月/次年 2 月各一期")

        // 每 6 个月
        let semiannual = RecurrenceSpec.spec(for: .semiannual, anchor: anchor)!
        let semiannualDates = expanded(
            of: makeEvent(id: "p-semiannual", start: anchor, spec: semiannual),
            from: wide.0, to: wide.1
        ).compactMap(\.startDate).sorted()
        XCTAssertEqual(
            semiannualDates,
            [date(2026, 11, 6), date(2027, 5, 6), date(2027, 11, 6)],
            "每6个月：13 个月应 3 期"
        )

        // 每年
        let yearly = RecurrenceSpec.spec(for: .yearly, anchor: anchor)!
        let yearlyDates = expanded(
            of: makeEvent(id: "p-yearly", start: anchor, spec: yearly),
            from: wide.0, to: date(2029, 1, 1, 0)
        ).compactMap(\.startDate).sorted()
        XCTAssertEqual(
            yearlyDates,
            [date(2026, 11, 6), date(2027, 11, 6), date(2028, 11, 6)],
            "每年：应逐年出现"
        )

        // 自定义：多选星期（周一/周三）
        let multiWeekday = RecurrenceSpec(frequency: .weekly, interval: 1, weekdays: [2, 4])
        XCTAssertEqual(
            days(expanded(of: makeEvent(id: "p-multi", start: anchor, spec: multiWeekday), from: december.0, to: december.1)),
            [2, 7, 9, 14, 16, 21, 23, 28, 30],
            "自定义多选星期：12 月应 9 期"
        )

        // 自定义：每月最后一个周五
        let lastFriday = RecurrenceSpec(frequency: .monthly, interval: 1, nthWeekday: NthWeekday(nth: -1, weekday: 6))
        let lastFridayDates = expanded(
            of: makeEvent(id: "p-nth", start: date(2026, 11, 27), spec: lastFriday),
            from: date(2026, 11, 1, 0), to: date(2027, 3, 1, 0)
        ).compactMap(\.startDate).sorted()
        XCTAssertEqual(
            lastFridayDates,
            [date(2026, 11, 27), date(2026, 12, 25), date(2027, 1, 29), date(2027, 2, 26)],
            "自定义第 N 个周几：应逐月产出当月最后一个周五"
        )

        // 自定义：每年按月（每年 3 月 6 日）
        let yearlyByMonth = RecurrenceSpec(frequency: .yearly, interval: 1, monthDay: 6, months: [3])
        XCTAssertEqual(
            expanded(
                of: makeEvent(id: "p-yearly-month", start: anchor, spec: yearlyByMonth),
                from: wide.0, to: wide.1
            ).compactMap(\.startDate).sorted(),
            [date(2027, 3, 6)],
            "自定义每年按月：锚点 11 月之后的首期应顺延到次年 3 月"
        )
    }

    // MARK: - A2. 真实存储行（原样 JSON）经月历谓词 + 合并 + 列表三链路

    func testRealStoredWorkdayRowVisibleInNovemberMonth() throws {
        // 抽样自真实库：~ZRECURRENCETYPERAW='每周'，ZSTARTDATE=2026-11-06，origin=NULL
        let realJSON = #"{"interval":1,"weekdays":[2,3,4,5,6],"end":{"mode":"never"},"months":[],"frequency":"weekly"}"#
        let event = CachedEvent(
            eventID: "real-row",
            title: "工作日常规",
            startDate: date(2026, 11, 6, 0),
            endDate: date(2026, 11, 6, 1),
            isAllDay: false,
            calendarID: "reminder",
            calendarTitle: "提醒",
            calendarColorHex: "#FF9500",
            category: .user,
            recurrenceType: .weekly,
            recurrenceSpecJSON: realJSON
        )
        context.insert(event)
        XCTAssertNil(event.originStartDate, "真实行 origin 为 NULL")

        // 11 月月历窗口（CalendarGridView：firstDay-7 ... firstDay+38）
        let windowStart = date(2026, 10, 25, 0)
        let windowEnd = date(2026, 12, 9, 0)
        let predicate = CachedEvent.monthWindowPredicate(windowStart: windowStart, windowEnd: windowEnd)
        let rows = try context.fetch(FetchDescriptor<CachedEvent>(predicate: predicate))
        XCTAssertTrue(rows.contains { $0.eventID == "real-row" }, "月历 @Query 谓词必须命中循环 base")

        let merged = EventCacheService.shared.mergedDisplayEvents(
            from: rows, windowStart: windowStart, windowEnd: windowEnd, context: context
        )
        let mergedDates = merged.compactMap(\.startDate).map { Calendar.current.startOfDay(for: $0) }
        XCTAssertEqual(merged.count, 23, "月历 11 月窗口应产出 23 期工作日，实际 \(merged.count)")
        for future in [date(2026, 11, 9, 0), date(2026, 11, 13, 0), date(2026, 11, 16, 0), date(2026, 12, 8, 0)] {
            XCTAssertTrue(
                mergedDates.contains(Calendar.current.startOfDay(for: future)),
                "未来日期 \(future) 必须在月历出现"
            )
        }

        // 待办列表链路（与徽标倒计时同为 getEvents）
        let listed = EventCacheService.shared.getEvents(from: windowStart, to: windowEnd)
        let listedDates = listed.compactMap(\.startDate).map { Calendar.current.startOfDay(for: $0) }
        XCTAssertEqual(listed.count, 23, "getEvents 应看到同 23 期，实际 \(listed.count)")
        XCTAssertTrue(listedDates.contains(Calendar.current.startOfDay(for: date(2026, 11, 9, 0))))
    }

    // MARK: - A3. 提醒调度 / 徽标倒计时链路

    func testSchedulingSeesFutureRecurringOccurrence() throws {
        let now = date(2026, 11, 7, 10)
        let base = makeEvent(id: "sched-daily", start: date(2026, 11, 1), type: .daily)
        let rows = expanded(of: base, from: now.addingTimeInterval(-60), to: date(2026, 11, 20, 0))

        let next = ReminderAlertService.nextTriggerTime(
            now: now, events: rows, snoozeRecords: [], context: context
        )
        XCTAssertEqual(next, date(2026, 11, 8), "准点调度必须看到未来循环实例（次日 09:00），实际 \(String(describing: next))")
    }

    // MARK: - B. 转单次：未来 0 行，历史 N 行（A→B 连续断言）

    func testDailyActiveThenConverted() throws {
        let spec = RecurrenceSpec.spec(for: .daily, anchor: date(2026, 11, 1))!
        let base = makeEvent(id: "ab-daily", start: date(2026, 11, 6), spec: spec)
        base.completedOccurrenceDates = [date(2026, 11, 1), date(2026, 11, 2), date(2026, 11, 3), date(2026, 11, 4), date(2026, 11, 5)]

        // A：循环态未来有行
        let activeFuture = expanded(of: base, from: date(2026, 11, 6, 0), to: date(2026, 11, 20, 0))
        XCTAssertGreaterThanOrEqual(activeFuture.count, 14, "A 每天循环未来必须有行，实际 \(activeFuture.count)")

        // 转单次（与 updateEventRecurrence(newSpec: nil) 一致）
        base.recurrenceType = RecurrenceType.none
        base.recurrenceSpecJSON = nil
        base.originStartDate = nil

        // B：未来 0 行（旧实现会把游标本体 Nov 6 当未来行产出）
        let convertedFuture = expanded(of: base, from: date(2026, 11, 6, 0), to: date(2026, 12, 1, 0))
        XCTAssertEqual(convertedFuture.count, 0, "B 转单次后未来不得有任何实例，实际 \(convertedFuture.count)")

        // B：历史仅 5 行且全为已完成（旧实现多出未完成的游标本体行 → 6）
        let history = expanded(of: base, from: date(2026, 10, 1, 0), to: date(2026, 11, 10, 0))
        XCTAssertEqual(history.count, 5, "B 历史窗口只应有 5 条已完成记录，实际 \(history.count)")
        XCTAssertTrue(history.allSatisfy(\.isCompleted), "B 历史行必须全部为已完成样式")
        XCTAssertEqual(Set(history.compactMap(\.startDate)), Set(base.completedOccurrenceDates))
    }

    func testMonthlyActiveThenConverted() throws {
        let spec = RecurrenceSpec.spec(for: .monthly, anchor: date(2026, 5, 6))!
        let base = makeEvent(id: "ab-monthly", start: date(2026, 8, 6), spec: spec)
        base.completedOccurrenceDates = [date(2026, 5, 6), date(2026, 6, 6), date(2026, 7, 6)]

        XCTAssertEqual(
            expanded(of: base, from: date(2026, 8, 6, 0), to: date(2026, 12, 1, 0)).count, 4,
            "A 每月循环未来应有 4 期"
        )

        base.recurrenceType = RecurrenceType.none
        base.recurrenceSpecJSON = nil
        base.originStartDate = nil

        XCTAssertEqual(
            expanded(of: base, from: date(2026, 8, 6, 0), to: date(2027, 1, 1, 0)).count, 0,
            "B 每月转单次后未来必须 0 行"
        )
        let history = expanded(of: base, from: date(2026, 5, 1, 0), to: date(2026, 8, 1, 0))
        XCTAssertEqual(history.count, 3, "B 历史应有 3 条已完成记录，实际 \(history.count)")
        XCTAssertTrue(history.allSatisfy(\.isCompleted))
    }

    func testCustomMultiWeekdayActiveThenConverted() throws {
        let spec = RecurrenceSpec(frequency: .weekly, interval: 1, weekdays: [2, 4])
        let base = makeEvent(id: "ab-multi", start: date(2026, 11, 9), spec: spec)
        base.completedOccurrenceDates = [date(2026, 11, 2), date(2026, 11, 4), date(2026, 11, 6)]

        XCTAssertGreaterThanOrEqual(
            expanded(of: base, from: date(2026, 11, 9, 0), to: date(2026, 12, 1, 0)).count, 6,
            "A 自定义多选星期未来应有行"
        )

        base.recurrenceType = RecurrenceType.none
        base.recurrenceSpecJSON = nil
        base.originStartDate = nil

        XCTAssertEqual(
            expanded(of: base, from: date(2026, 11, 8, 0), to: date(2026, 12, 1, 0)).count, 0,
            "B 自定义多选星期转单次后未来必须 0 行"
        )
        let history = expanded(of: base, from: date(2026, 11, 1, 0), to: date(2026, 11, 8, 0))
        XCTAssertEqual(history.count, 3, "B 历史应有 3 条已完成记录，实际 \(history.count)")
        XCTAssertTrue(history.allSatisfy(\.isCompleted))
    }

    func testConvertedRowProducesNoReminderTrigger() throws {
        let base = makeEvent(id: "b-no-trigger", start: date(2026, 5, 6), type: RecurrenceType.none)
        base.completedOccurrenceDates = [date(2026, 5, 6), date(2026, 6, 6)]
        base.originStartDate = nil
        base.startDate = date(2027, 1, 6)  // 游标落在未来

        let rows = expanded(of: base, from: date(2026, 12, 1, 0), to: date(2027, 2, 1, 0))
        XCTAssertEqual(rows.count, 0, "B 转单次后列表/调度候选不得含未来行")
        XCTAssertNil(
            ReminderAlertService.nextTriggerTime(
                now: date(2026, 12, 1, 0), events: [base], snoozeRecords: [], context: context
            ),
            "B 转单次任务不得产生任何提醒调度"
        )
    }

    func testConvertedRetainsPresentationFieldsInHistory() throws {
        let event = makeEvent(id: "converted-style", start: date(2026, 5, 6), type: RecurrenceType.none)
        event.completedOccurrenceDates = [date(2026, 5, 6), date(2026, 6, 6)]
        event.priority = EventPriority.high.rawValue
        event.eventColorHex = "#FF3B30"
        event.isReminder = true
        event.reminderMinutes = 30
        event.originStartDate = nil

        let history = expanded(of: event, from: date(2026, 5, 1, 0), to: date(2026, 7, 1, 0))
        XCTAssertEqual(history.count, 2, "B 历史行数应精确对应完成期次")
        for row in history {
            XCTAssertTrue(row.isCompleted)
            XCTAssertEqual(row.priority, EventPriority.high.rawValue)
            XCTAssertEqual(row.eventColorHex, "#FF3B30")
            XCTAssertTrue(row.isReminder)
            XCTAssertEqual(row.reminderMinutes, 30)
        }
    }

    // MARK: - A4. 外部回流不得降级本地循环规则（差档位推导抹掉多选星期）

    func testMergeDoesNotDegradeRichSpecWhenCarrierLacksSpec() throws {
        let weekend = RecurrenceSpec(frequency: .weekly, interval: 1, weekdays: [1, 7])
        let base = makeEvent(id: "merge-rich", start: date(2026, 11, 6), spec: weekend)
        let ek = CalendarEvent(
            id: "merge-rich",
            title: "周末任务",
            startDate: date(2026, 11, 6),
            endDate: date(2026, 11, 6).addingTimeInterval(3600),
            isAllDay: false,
            calendarID: "reminder",
            calendarTitle: "提醒",
            calendarColorHex: "#FF9500",
            category: .user,
            isCompleted: false,
            priority: 0,
            isReminder: true,
            recurrenceType: .weekly,
            reminderMinutes: 0,
            reminderAlarmIsAbsolute: false,
            eventColorHex: nil,
            notes: nil
        )
        XCTAssertNil(ek.recurrenceSpec, "模拟未携带 spec 的事件载体（旧链路/规则回流缺失）")

        _ = EventCacheService.mergeReminderUpdate(existing: base, ek: ek)

        XCTAssertEqual(
            RecurrenceSpec.decode(base.recurrenceSpecJSON)?.weekdays, [1, 7],
            "回流不得把「周末」降级为单星期，否则未来实例大面积消失"
        )
        let weekendRows = expanded(of: base, from: date(2026, 11, 7, 0), to: date(2026, 12, 1, 0))
        for row in weekendRows {
            let weekday = Calendar.current.component(.weekday, from: row.startDate!)
            XCTAssertTrue([1, 7].contains(weekday), "降级后产出了非周末实例: \(row.startDate!)")
        }
        XCTAssertGreaterThanOrEqual(weekendRows.count, 8, "11 月剩余周末至少 8 期，实际 \(weekendRows.count)")
    }

    // MARK: - A5. 存量兜底：档位非 none 但 spec 无法解析的行产出本体行

    func testCustomTypeWithoutSpecJSONProducesBaseRow() throws {
        // 存量行形态：recurrenceType 非循环语义档（.custom）且 specJSON 缺失——
        // legacy 推导对 .custom 返回 nil，展开兜底产出本体行；
        // 旧行为（guard let spec 失败即返回空）下该行完全不可见
        let base = makeEvent(id: "custom-nospec", start: date(2026, 11, 6), type: .custom)
        XCTAssertNil(base.recurrenceSpec, "前置确认：.custom 无 specJSON 时推导结果为 nil")

        let rows = expanded(of: base, from: date(2026, 11, 6, 0), to: date(2026, 11, 8, 0))
        XCTAssertEqual(rows.count, 1, "无 spec 的存量循环档应兜底产出 1 条本体行，实际 \(rows.count)")
        XCTAssertEqual(rows.first?.eventID, "custom-nospec")
        XCTAssertEqual(rows.first?.startDate, date(2026, 11, 6))
        XCTAssertFalse(rows.first?.isCompleted ?? true, "兜底行保持本体未完成态")
    }

    // MARK: - Helpers

    private func makeEvent(id: String, start: Date, type: RecurrenceType? = nil, spec: RecurrenceSpec? = nil) -> CachedEvent {
        let resolvedType = spec?.legacyType ?? type ?? .none
        let event = CachedEvent(
            eventID: id,
            title: "循环-\(id)",
            startDate: start,
            endDate: start.addingTimeInterval(3600),
            isAllDay: false,
            calendarID: "reminder",
            calendarTitle: "提醒",
            calendarColorHex: "#FF9500",
            category: .user,
            recurrenceType: resolvedType,
            recurrenceSpecJSON: spec?.jsonString
        )
        event.originStartDate = start
        context.insert(event)
        return event
    }
}
