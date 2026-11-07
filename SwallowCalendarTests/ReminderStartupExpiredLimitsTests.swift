//
//  ReminderStartupExpiredLimitsTests.swift
//  SwallowCalendarTests
//
//  审计 H1/H2/M3/M6 回归：
//  H1 启动过期候选查询失败必须抛出（不降级、不置位完成标志、可重试）
//  H2 回溯窗口与弹窗上限生效，截断条数可被上层读取（弹窗内明示）
//  M3 循环规则更新失败必须向上反馈
//  M6 统一查询入口的失败通道可感知且区分「空结果」
//

import XCTest
import SwiftData
@testable import SwallowCalendar

@MainActor
final class ReminderStartupExpiredLimitsTests: XCTestCase {

    private struct Boom: Error {}

    private let alertedIDsKey = "ReminderAlertService.lastAlertedEventIDs"
    private let lastCheckTimeKey = "ReminderAlertService.lastCheckTime"

    override func setUp() async throws {
        resetState()
    }

    override func tearDown() async throws {
        resetState()
    }

    private func resetState() {
        ReminderAlertService.shared.resetForTesting()
        ReminderAlertService.shared.startupRecurringFetcherForTesting = nil
        UserDefaults.standard.removeObject(forKey: alertedIDsKey)
        UserDefaults.standard.removeObject(forKey: lastCheckTimeKey)
        ReminderAlertWindowController.shared.close()
    }

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: CachedEvent.self, configurations: config)
    }

    @discardableResult
    private func insertEvent(
        into context: ModelContext,
        eventID: String,
        startDate: Date?,
        recurrenceType: RecurrenceType = .none,
        originStartDate: Date? = nil
    ) throws -> CachedEvent {
        let event = CachedEvent(
            eventID: eventID,
            title: eventID,
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
        context.insert(event)
        try context.save()
        return event
    }

    // MARK: - H1

    /// 循环候选查询失败必须抛出，不得返回未展开的 rawEvents
    func testExpiredCandidatesThrowsWhenRecurringFetchFails() throws {
        let container = try makeContainer()
        let context = container.mainContext

        XCTAssertThrowsError(
            try ReminderAlertService.expiredCheckCandidates(
                rawEvents: [],
                upperBound: Date(),
                context: context,
                recurringBaseFetcher: { throw Boom() }
            )
        ) { error in
            XCTAssertTrue(error is Boom, "失败必须原样上抛，不得降级为空结果")
        }
    }

    /// 启动检查失败不置位完成标志，且下一次调用能重试成功
    func testStartupExpiredCheckRetriesAfterQueryFailure() async throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)

        ReminderAlertService.shared.startupRecurringFetcherForTesting = { throw Boom() }
        await ReminderAlertService.shared.checkExpiredEvents()
        XCTAssertFalse(
            ReminderAlertService.shared.startupExpiredCheckCompletedForTesting,
            "查询失败不得置位完成标志，否则本轮永不重试"
        )
        XCTAssertFalse(
            ReminderAlertWindowController.shared.isWindowVisible,
            "失败时不得用未展开结果弹出过期提醒"
        )

        ReminderAlertService.shared.startupRecurringFetcherForTesting = nil
        await ReminderAlertService.shared.checkExpiredEvents()
        XCTAssertTrue(
            ReminderAlertService.shared.startupExpiredCheckCompletedForTesting,
            "失败后再次调用应重试并成功置位"
        )
    }

    // MARK: - H2

    /// 回溯窗口为「30 天前的自然日零点」
    func testStartupLookbackBoundIsThirtyDaysStartOfDay() {
        let now = Date()
        let lower = ReminderAlertService.startupExpiredLowerBound(now: now)
        let expected = Calendar.current.startOfDay(
            for: Calendar.current.date(byAdding: .day, value: -30, to: now) ?? now
        )
        XCTAssertEqual(lower, expected)
    }

    /// 超出回溯窗口的循环实例不再进入启动过期候选
    func testExpiredCandidatesExcludeOccurrencesOlderThanLookback() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let now = Date()
        let lower = ReminderAlertService.startupExpiredLowerBound(now: now)
        let fortyDaysAgo = now.addingTimeInterval(-40 * 86_400)
        try insertEvent(
            into: context,
            eventID: "daily-old",
            startDate: fortyDaysAgo,
            recurrenceType: .daily,
            originStartDate: fortyDaysAgo
        )

        let candidates = try ReminderAlertService.expiredCheckCandidates(
            rawEvents: [],
            upperBound: now,
            lowerBound: lower,
            context: context
        )

        XCTAssertFalse(candidates.isEmpty, "窗口内仍应有近期实例")
        XCTAssertTrue(
            candidates.allSatisfy { ($0.startDate ?? .distantPast) >= lower },
            "早于回溯窗口的实例不得进入候选，避免冷启动扫描全历史"
        )
        XCTAssertLessThanOrEqual(candidates.count, 31, "30 天日循环最多约 31 个实例")
    }

    /// 上限截断保留最近过期行，并给出被隐藏条数
    func testCappedExpiredRowsKeepsMostRecentAndReportsHidden() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let now = Date()
        for index in 0..<35 {
            try insertEvent(
                into: context,
                eventID: "row-\(index)",
                startDate: now.addingTimeInterval(-Double(index) * 60)
            )
        }
        let events = try context.fetch(FetchDescriptor<CachedEvent>())
        let capped = ReminderAlertService.cappedExpiredRows(events)

        XCTAssertEqual(capped.visible.count, 30)
        XCTAssertEqual(capped.hiddenCount, 5)
        XCTAssertEqual(capped.visible.first?.eventID, "row-0", "最近过期优先展示")
        XCTAssertEqual(capped.visible.last?.eventID, "row-29")
    }

    /// 未超上限时不截断
    func testCappedExpiredRowsDoesNotTruncateUnderLimit() throws {
        let container = try makeContainer()
        let context = container.mainContext
        for index in 0..<3 {
            try insertEvent(
                into: context,
                eventID: "few-\(index)",
                startDate: Date().addingTimeInterval(-Double(index) * 60)
            )
        }
        let events = try context.fetch(FetchDescriptor<CachedEvent>())
        let capped = ReminderAlertService.cappedExpiredRows(events)
        XCTAssertEqual(capped.visible.count, 3)
        XCTAssertEqual(capped.hiddenCount, 0)
    }

    /// 截断条数必须传到弹窗层（弹窗内展示「另有 N 条」）
    func testWindowControllerReceivesHiddenCount() {
        ReminderAlertWindowController.shared.show(
            events: [],
            isExpired: true,
            hiddenCount: 5,
            onCompleteAll: {}
        )
        XCTAssertEqual(ReminderAlertWindowController.shared.lastHiddenCount, 5)
        ReminderAlertWindowController.shared.close()
    }

    // MARK: - M3

    /// 循环规则更新找不到本体时必须抛出（保存链路可感知，不得静默成功）
    func testUpdateRecurrenceThrowsWhenEventMissing() throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        let service = CalendarService()

        XCTAssertThrowsError(
            try service.updateEventRecurrence(
                eventID: "missing-id",
                newSpec: RecurrenceSpec(frequency: .daily)
            )
        ) { error in
            guard case CalendarService.RecurrenceUpdateError.eventNotFound(let id) = error else {
                return XCTFail("应抛出 eventNotFound，实际: \(error)")
            }
            XCTAssertEqual(id, "missing-id")
            XCTAssertTrue(error.localizedDescription.contains("missing-id"))
        }
    }

    // MARK: - M6

    /// 统一执行体的失败通道：包裹操作名并上抛
    func testCacheFetchPerformWrapsFailure() {
        XCTAssertThrowsError(try CacheFetch.perform(operation: "测试查询") { throw Boom() }) { error in
            guard let failure = error as? CacheFetch.Failure else {
                return XCTFail("应包装为 CacheFetch.Failure，实际: \(error)")
            }
            XCTAssertTrue(failure.errorDescription?.contains("测试查询") == true)
        }
    }

    /// 空结果返回空数组（非 nil），与失败语义区分
    func testCacheFetchOptionalDistinguishesEmptyFromFailure() throws {
        let container = try makeContainer()
        let rows = CacheFetch.optional(
            FetchDescriptor<CachedEvent>(),
            in: container.mainContext,
            operation: "空查询"
        )
        XCTAssertEqual(rows?.count, 0, "空结果应为 [] 而不是 nil")
    }
}
