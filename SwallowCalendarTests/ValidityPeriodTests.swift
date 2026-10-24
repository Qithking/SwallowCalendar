//
//  ValidityPeriodTests.swift
//  SwallowCalendarTests
//
//  任务有效期区间（spec/task-validity-period AC-1~AC-6）
//  R1: ValidityPeriod 归一化 + CachedEvent.isWithinValidity 闭区间判定
//  Source: plan/task-validity-period.md step 1/2/3
//
//  日期锚点：2026-10-26 为周一
//

import XCTest
import SwiftData
@testable import SwallowCalendar

@MainActor
final class ValidityPeriodTests: XCTestCase {

    // MARK: - helpers（仿 EventExpansionTests）

    /// 仅注册 CachedEvent 的内存 SwiftData 容器，注入 EventCacheService.shared
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: CachedEvent.self, configurations: config)
    }

    /// 本地时区日期构造
    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return Calendar.current.date(from: components)!
    }

    /// 构造循环任务并落库，直赋有效期字段（归一化落库由 createEvent 链路负责，此处绕过）
    @discardableResult
    private func insertRecurring(
        into context: ModelContext,
        eventID: String = "v-base",
        startDate: Date,
        validStart: Date? = nil,
        validEnd: Date? = nil,
        completed: [Date] = []
    ) throws -> CachedEvent {
        let event = CachedEvent(
            eventID: eventID,
            title: "循环任务",
            startDate: startDate,
            endDate: startDate,
            isAllDay: false,
            calendarID: "test",
            calendarTitle: "测试日历",
            calendarColorHex: "#007AFF",
            recurrenceType: .daily
        )
        event.validStartDate = validStart
        event.validEndDate = validEnd
        event.completedOccurrenceDates = completed
        context.insert(event)
        try context.save()
        return event
    }

    /// 窗口 [day 00:00, day+days 00:00)
    private func dayWindow(_ year: Int, _ month: Int, _ day: Int, days: Int = 1) -> (Date, Date) {
        let start = date(year, month, day)
        let end = Calendar.current.date(byAdding: .day, value: days, to: start)!
        return (start, end)
    }

    /// occurrence 复合 ID 快捷构造
    private func occID(_ baseID: String, _ occurrence: Date) -> String {
        CachedEvent.makeOccurrenceID(baseID: baseID, occurrence: occurrence)
    }

    // MARK: - R1: ValidityPeriod 归一化（plan step 1）

    func testNormalizedStartDateIsDayStart() {
        // 任意时刻的 start 归一化为当天 00:00:00
        let period = ValidityPeriod(start: date(2026, 10, 26, 15, 30, 20), end: nil)
        XCTAssertEqual(period.normalizedStartDate, date(2026, 10, 26, 0, 0, 0))
        XCTAssertNil(ValidityPeriod(start: nil, end: nil).normalizedStartDate)
    }

    func testNormalizedEndDateIsDayEnd() {
        // 任意时刻的 end 归一化为当天 23:59:59
        let period = ValidityPeriod(start: nil, end: date(2026, 10, 31, 8, 0, 0))
        XCTAssertEqual(period.normalizedEndDate, date(2026, 10, 31, 23, 59, 59))
        XCTAssertNil(ValidityPeriod(start: nil, end: nil).normalizedEndDate)
    }

    // MARK: - R1: isWithinValidity 闭区间判定（plan step 3）

    func testUnlimitedWhenBothNil() throws {
        // AC-1：双端未设置 = 不限制任务
        let container = try makeContainer()
        let context = ModelContext(container)
        let event = try insertRecurring(into: context, startDate: date(2026, 10, 26, 9, 0))
        XCTAssertTrue(event.isWithinValidity(date(2026, 1, 1, 0, 0)))
        XCTAssertTrue(event.isWithinValidity(date(2030, 12, 31, 23, 59)))
    }

    func testOnlyStartClosedIntervalInclusive() throws {
        // 只设开始端：起点当天含端点，之前越界
        let container = try makeContainer()
        let context = ModelContext(container)
        let event = try insertRecurring(
            into: context,
            startDate: date(2026, 10, 26, 9, 0),
            validStart: date(2026, 10, 26, 0, 0)
        )
        XCTAssertTrue(event.isWithinValidity(date(2026, 10, 26, 0, 0)))
        XCTAssertTrue(event.isWithinValidity(date(2026, 10, 26, 9, 0)))
        XCTAssertFalse(event.isWithinValidity(date(2026, 10, 25, 23, 59)))
    }

    func testOnlyEndClosedIntervalInclusive() throws {
        // 只设结束端：终点当天 23:59:59 内含端点，次日 0 点越界
        let container = try makeContainer()
        let context = ModelContext(container)
        let event = try insertRecurring(
            into: context,
            startDate: date(2026, 10, 26, 9, 0),
            validEnd: date(2026, 10, 31, 23, 59, 59)
        )
        XCTAssertTrue(event.isWithinValidity(date(2026, 10, 31, 0, 0)))
        XCTAssertTrue(event.isWithinValidity(date(2026, 10, 31, 23, 59, 59)))
        XCTAssertFalse(event.isWithinValidity(date(2026, 11, 1, 0, 0)))
    }

    func testBothEndsInterval() throws {
        // 双端：区间内 true，两端之外 false
        let container = try makeContainer()
        let context = ModelContext(container)
        let event = try insertRecurring(
            into: context,
            startDate: date(2026, 10, 26, 9, 0),
            validStart: date(2026, 10, 26, 0, 0),
            validEnd: date(2026, 10, 31, 23, 59, 59)
        )
        XCTAssertTrue(event.isWithinValidity(date(2026, 10, 28, 12, 0)))
        XCTAssertFalse(event.isWithinValidity(date(2026, 10, 20, 0, 0)))
        XCTAssertFalse(event.isWithinValidity(date(2026, 11, 2, 0, 0)))
    }

    // MARK: - R2: 展开层未完成序列过滤（plan step 4② / AC-2 AC-3）

    func testExpansionFiltersOccurrencesBeforeValidStart() throws {
        // startDate=10-26、validStart=10-28：窗口 [10-24,10-29) 内仅 10-28 产出
        let container = try makeContainer()
        let context = ModelContext(container)
        EventCacheService.shared.configure(with: container)
        _ = try insertRecurring(into: context, startDate: date(2026, 10, 26, 9, 0), validStart: date(2026, 10, 28, 0, 0))
        let (start, end) = dayWindow(2026, 10, 24, days: 5)
        let events = EventCacheService.shared.getEvents(from: start, to: end)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(CachedEvent.parseOccurrenceID(events[0].eventID)?.occurrence, date(2026, 10, 28, 9, 0))
    }

    func testExpansionFiltersOccurrencesAfterValidEnd() throws {
        // startDate=10-26、validEnd=10-27 23:59:59：窗口 [10-24,10-31) 内仅 10-26、10-27 产出
        let container = try makeContainer()
        let context = ModelContext(container)
        EventCacheService.shared.configure(with: container)
        _ = try insertRecurring(into: context, startDate: date(2026, 10, 26, 9, 0), validEnd: date(2026, 10, 27, 23, 59, 59))
        let (start, end) = dayWindow(2026, 10, 24, days: 7)
        let events = EventCacheService.shared.getEvents(from: start, to: end)
        let occs = events.compactMap { CachedEvent.parseOccurrenceID($0.eventID)?.occurrence }
        XCTAssertEqual(occs, [date(2026, 10, 26, 9, 0), date(2026, 10, 27, 9, 0)])
    }

    // MARK: - R3: 展开层历史行过滤（plan step 4①）

    func testExpansionFiltersHistoryRowOutsideValidity() throws {
        // 已完成 occurrence 在有效期外 → 历史行不产出（10-26 完成记录为设置有效期前的遗留）
        let container = try makeContainer()
        let context = ModelContext(container)
        EventCacheService.shared.configure(with: container)
        _ = try insertRecurring(
            into: context,
            startDate: date(2026, 10, 26, 9, 0),
            validStart: date(2026, 10, 28, 0, 0),
            completed: [date(2026, 10, 26, 9, 0)]
        )
        let (start, end) = dayWindow(2026, 10, 24, days: 5)
        let events = EventCacheService.shared.getEvents(from: start, to: end)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(CachedEvent.parseOccurrenceID(events[0].eventID)?.occurrence, date(2026, 10, 28, 9, 0))
        XCTAssertFalse(events[0].isCompleted)
    }

    // MARK: - R4: 冻结场景 done 行去重（plan step 4②）

    func testFrozenStateNoDuplicateHistoryRow() throws {
        // 冻结后 startDate 停在最后已完成 X：② 不再为 done 行产出重复行，
        // 历史行由 ① 独家产出（10-26、10-27 各恰好一行）
        let container = try makeContainer()
        let context = ModelContext(container)
        EventCacheService.shared.configure(with: container)
        _ = try insertRecurring(
            into: context,
            startDate: date(2026, 10, 27, 9, 0),
            validEnd: date(2026, 10, 27, 23, 59, 59),
            completed: [date(2026, 10, 26, 9, 0), date(2026, 10, 27, 9, 0)]
        )
        let (start, end) = dayWindow(2026, 10, 26, days: 3)
        let events = EventCacheService.shared.getEvents(from: start, to: end)
        let occs = events.compactMap { CachedEvent.parseOccurrenceID($0.eventID)?.occurrence }
        XCTAssertEqual(occs, [date(2026, 10, 26, 9, 0), date(2026, 10, 27, 9, 0)])
        XCTAssertTrue(events.allSatisfy { $0.isCompleted })
    }

    // MARK: - R5: 完成推进冻结（plan step 5c / AC-4）

    /// 完成 occurrence 后 target 越过有效期结束端 → 冻结：startDate 停在最后已完成 X，仅记历史
    func testCompleteFreezesWhenTargetBeyondValidEnd() async throws {
        // 测试环境 EventKit 无对应记录 → EK 侧走 NOT-FOUND 兜底，缓存侧照写（仿 RecurringCompletionTests）
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        let calendarService = CalendarService()
        let d0 = date(2026, 10, 26, 9, 0)
        let d1 = date(2026, 10, 27, 9, 0)
        let cached = try insertRecurring(
            into: container.mainContext,
            eventID: "v-freeze",
            startDate: d0,
            validEnd: date(2026, 10, 27, 23, 59, 59)
        )

        // 完成 10-26：target=10-27 在有效期内，正常推进
        await calendarService.toggleEventCompleted(eventID: occID("v-freeze", d0), isCompleted: true)
        XCTAssertEqual(cached.startDate?.timeIntervalSince1970 ?? 0, d1.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(cached.completedOccurrenceDates, [d0])

        // 完成 10-27：target=10-28 越过 validEnd → 冻结：startDate 不推进，仅记历史
        await calendarService.toggleEventCompleted(eventID: occID("v-freeze", d1), isCompleted: true)
        XCTAssertEqual(cached.startDate?.timeIntervalSince1970 ?? 0, d1.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(cached.completedOccurrenceDates, [d0, d1])
        XCTAssertFalse(cached.isCompleted)
    }

    // MARK: - R6: 完成推进补齐（plan step 5b / AC-5，防御性分支）

    /// startDate 落后于有效期开始端（编辑把开始端改到未来产生空档）时，
    /// 完成后 target 逐周期推进到首个 >= validStart
    func testCompleteCatchUpToValidStart() async throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        let calendarService = CalendarService()
        let d0 = date(2026, 10, 26, 9, 0)
        let target = date(2026, 11, 2, 9, 0)
        let cached = try insertRecurring(
            into: container.mainContext,
            eventID: "v-catchup",
            startDate: d0,
            validStart: date(2026, 11, 2, 0, 0)
        )

        await calendarService.toggleEventCompleted(eventID: occID("v-catchup", d0), isCompleted: true)

        // 补齐：跳过 10-27~11-01 空档，startDate 直达首个有效日
        XCTAssertEqual(cached.startDate?.timeIntervalSince1970 ?? 0, target.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(cached.completedOccurrenceDates, [d0])
    }

    // MARK: - R8: 切单次对称清除有效期（plan step 8 / AC-6）

    /// 周期改 1 次：有效期区间随之清除（单次任务无周期语义）
    func testRecurrenceToNoneClearsValidityPeriod() throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        let calendarService = CalendarService()
        let d0 = date(2026, 10, 26, 9, 0)
        let cached = try insertRecurring(
            into: container.mainContext,
            eventID: "v-none",
            startDate: d0,
            validStart: date(2026, 10, 26, 0, 0),
            validEnd: date(2026, 10, 31, 23, 59, 59)
        )

        calendarService.updateEventRecurrence(eventID: "v-none", newRecurrenceType: .none)

        XCTAssertNil(cached.validStartDate)
        XCTAssertNil(cached.validEndDate)
        XCTAssertEqual(cached.completedOccurrenceDates, [])
    }

    /// 非切单次的周期类型变更：有效期保持不动
    func testChangeRecurrenceTypeKeepsValidityPeriod() throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        let calendarService = CalendarService()
        let d0 = date(2026, 10, 26, 9, 0)
        let cached = try insertRecurring(
            into: container.mainContext,
            eventID: "v-weekly",
            startDate: d0,
            validStart: date(2026, 10, 26, 0, 0),
            validEnd: date(2026, 10, 31, 23, 59, 59)
        )

        calendarService.updateEventRecurrence(eventID: "v-weekly", newRecurrenceType: .weekly)

        XCTAssertEqual(cached.validStartDate, date(2026, 10, 26, 0, 0))
        XCTAssertEqual(cached.validEndDate, date(2026, 10, 31, 23, 59, 59))
    }
}
