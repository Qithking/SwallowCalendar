//
//  RecurringConversionHistoryPersistenceTests.swift
//  SwallowCalendarTests
//
//  回归：循环任务按真实完成链路写入历史，再改单次，历史必须落库且月历/已办可见
//

import XCTest
import SwiftData
@testable import SwallowCalendar

@MainActor
final class RecurringConversionHistoryPersistenceTests: XCTestCase {
    private var container: ModelContainer!

    override func setUp() async throws {
        try await super.setUp()
        container = try ModelContainer(
            for: CachedEvent.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        EventCacheService.shared.configure(with: container)
        CalendarService.shared.suppressesSyncFailureAlert = true
    }

    override func tearDown() async throws {
        CalendarService.shared.suppressesSyncFailureAlert = false
        container = nil
        try await super.tearDown()
    }

    private var shanghaiCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 21) -> Date {
        shanghaiCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    /// 真实链路：完成 3 个 occurrence → updateEventRecurrence(.none) → 重新读取
    func testCompletedOccurrencesSurviveRecurringToSingleConversion() async throws {
        let first = date(2026, 10, 30)
        let event = CachedEvent(
            eventID: "conv-history",
            title: "测试每天",
            startDate: first,
            endDate: first,
            isAllDay: false,
            calendarID: "test",
            calendarTitle: "测试",
            calendarColorHex: "#007AFF",
            category: .user,
            isReminder: true,
            recurrenceType: .daily
        )
        event.originStartDate = first
        container.mainContext.insert(event)
        try container.mainContext.save()

        // 用真实完成链路（复合 occurrence ID）写入历史，而非直接改字段
        let occurrences = [first, date(2026, 10, 31), date(2026, 11, 1)]
        for occ in occurrences {
            await CalendarService.shared.toggleEventCompleted(
                eventID: CachedEvent.makeOccurrenceID(baseID: "conv-history", occurrence: occ),
                isCompleted: true,
                isReminder: true
            )
        }

        // 新上下文读取，确认历史已落库
        let afterCompletion = ModelContext(container)
        let completed = try XCTUnwrap(
            try afterCompletion.fetch(FetchDescriptor<CachedEvent>())
                .first { $0.eventID == "conv-history" }
        )
        XCTAssertEqual(completed.completedOccurrenceDates.count, 3, "完成历史未写入持久化存储")

        // 改单次
        CalendarService.shared.updateEventRecurrence(eventID: "conv-history", newRecurrenceType: .none)

        let afterConversion = ModelContext(container)
        let converted = try XCTUnwrap(
            try afterConversion.fetch(FetchDescriptor<CachedEvent>())
                .first { $0.eventID == "conv-history" }
        )
        XCTAssertEqual(converted.recurrenceType, .none)
        XCTAssertNil(converted.originStartDate)
        XCTAssertEqual(
            Set(converted.completedOccurrenceDates.map { $0.timeIntervalSince1970 }),
            Set(occurrences.map { $0.timeIntervalSince1970 }),
            "改单次后完成历史被清空（旧版本 updateEventRecurrence 的 nil 写法）"
        )

        // 月历历史窗口必须能看到 3 期已办
        let windowStart = date(2026, 9, 24, hour: 0)
        let windowEnd = date(2026, 11, 8, hour: 0)
        let predicate = CachedEvent.monthWindowPredicate(windowStart: windowStart, windowEnd: windowEnd)
        let rows = try afterConversion.fetch(FetchDescriptor<CachedEvent>(predicate: predicate))
        XCTAssertTrue(rows.contains { $0.eventID == "conv-history" }, "历史月份 @Query 未命中本体行")

        let merged = EventCacheService.shared.mergedDisplayEvents(
            from: rows,
            windowStart: windowStart,
            windowEnd: windowEnd,
            context: afterConversion
        )
        XCTAssertEqual(merged.filter(\.isCompleted).count, 3, "月历未展开出 3 期历史")
    }

    /// 真实链路（磁盘存储 + 编辑面板的调用顺序）：完成 3 期 → updateEvent → updateEventRecurrence(.none)
    /// → 用全新 ModelContainer 重开存储读回 → 历史期次必须可展开且月历/已办可见
    func testDiskBackedConversionKeepsHistoryVisibleAfterReopen() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sc-bug21-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("default.store")
        let diskContainer = try ModelContainer(
            for: CachedEvent.self,
            configurations: ModelConfiguration(url: storeURL)
        )
        EventCacheService.shared.configure(with: diskContainer)

        let first = date(2026, 10, 28)
        let event = CachedEvent(
            eventID: "disk-conv",
            title: "磁盘循环",
            startDate: first,
            endDate: first,
            isAllDay: false,
            calendarID: "test",
            calendarTitle: "测试",
            calendarColorHex: "#007AFF",
            category: .user,
            isReminder: true,
            recurrenceType: .daily,
            reminderMinutes: 30
        )
        event.originStartDate = first
        event.eventColorHex = "#FF3B30"
        event.priority = 2
        diskContainer.mainContext.insert(event)
        try diskContainer.mainContext.save()

        let occurrences = [first, date(2026, 10, 29), date(2026, 10, 30)]
        for occ in occurrences {
            await CalendarService.shared.toggleEventCompleted(
                eventID: CachedEvent.makeOccurrenceID(baseID: "disk-conv", occurrence: occ),
                isCompleted: true,
                isReminder: true
            )
        }

        // 编辑面板顺序：先 updateEvent（EK 未授权时提前返回），再 updateEventRecurrence
        try? CalendarService.shared.updateEvent(
            eventID: "disk-conv",
            title: "磁盘循环",
            startDate: nil,
            endDate: nil,
            isReminder: true,
            priority: nil,
            reminderOffsets: nil,
            color: nil
        )
        CalendarService.shared.updateEventRecurrence(eventID: "disk-conv", newRecurrenceType: .none)

        // 模拟应用重启：新容器打开同一磁盘文件
        let reopened = try ModelContainer(
            for: CachedEvent.self,
            configurations: ModelConfiguration(url: storeURL)
        )
        let ctx = ModelContext(reopened)
        let converted = try XCTUnwrap(
            try ctx.fetch(FetchDescriptor<CachedEvent>()).first { $0.eventID == "disk-conv" }
        )
        XCTAssertEqual(converted.recurrenceType, .none)
        XCTAssertNil(converted.originStartDate)
        XCTAssertEqual(
            Set(converted.completedOccurrenceDates.map { $0.timeIntervalSince1970 }),
            Set(occurrences.map { $0.timeIntervalSince1970 }),
            "磁盘存储中完成历史必须保留"
        )

        // 月历 @Query 取数 → 展开
        let windowStart = date(2026, 10, 20, hour: 0)
        let windowEnd = date(2026, 11, 8, hour: 0)
        let rows = try ctx.fetch(FetchDescriptor<CachedEvent>(
            predicate: CachedEvent.monthWindowPredicate(windowStart: windowStart, windowEnd: windowEnd)
        ))
        let merged = EventCacheService.shared.mergedDisplayEvents(
            from: rows, windowStart: windowStart, windowEnd: windowEnd, context: ctx
        )
        let historyRows = merged.filter(\.isCompleted)
        XCTAssertEqual(historyRows.count, 3, "月历未从完成历史反推出 3 期历史行")
        XCTAssertEqual(Set(historyRows.compactMap(\.startDate)), Set(occurrences))
        XCTAssertTrue(historyRows.allSatisfy { $0.eventColorHex == "#FF3B30" && $0.priority == 2 })

        // 已办列表口径：getEvents → isCompleted
        let completedList = EventCacheService.shared.getEvents(from: windowStart, to: windowEnd)
            .filter { $0.category == .user && $0.isCompleted }
        XCTAssertEqual(completedList.filter { $0.title == "磁盘循环" }.count, 3, "已办列表未见历史期次")
    }

    /// 历史行必须由 completedOccurrenceDatesJSON 反推，不得依赖游标 startDate：
    /// 转换后 HK/EK 到期日被清空（startDate == nil）时仍需产出 3 条历史行
    func testHistoryRowsDerivedWithoutCursorStartDate() throws {
        let container = try ModelContainer(
            for: CachedEvent.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        EventCacheService.shared.configure(with: container)
        let ctx = container.mainContext
        let base = CachedEvent(
            eventID: "no-cursor",
            title: "无游标历史",
            startDate: nil,
            endDate: nil,
            isAllDay: false,
            calendarID: "test",
            calendarTitle: "测试",
            calendarColorHex: "#007AFF",
            category: .user,
            isReminder: true,
            recurrenceType: .none
        )
        let dates = [date(2026, 10, 28), date(2026, 10, 29), date(2026, 10, 30)]
        base.completedOccurrenceDates = dates
        ctx.insert(base)
        try ctx.save()

        let rows = EventCacheService.shared.expandOccurrences(
            of: base,
            windowStart: date(2026, 10, 20, hour: 0),
            windowEnd: date(2026, 11, 8, hour: 0),
            context: ctx
        )
        let history = rows.filter(\.isCompleted)
        XCTAssertEqual(history.count, 3, "startDate 为空时历史行未从完成历史反推")
        XCTAssertEqual(Set(history.compactMap(\.startDate)), Set(dates))
        XCTAssertTrue(history.allSatisfy { $0.title == "无游标历史" })
    }
}
