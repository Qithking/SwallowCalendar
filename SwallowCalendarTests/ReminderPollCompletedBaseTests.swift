//
//  ReminderPollCompletedBaseTests.swift
//  SwallowCalendarTests
//
//  bug: poll-window-completed-base-recurring-miss
//  需求：常规 60s 轮询粗筛谓词含 !$0.isCompleted，把 base 行被旧版本完成操作
//        整条置位（EK isCompleted=true、无完成历史、游标不推进——R-1 修复前
//        实际行为）的循环任务排除，recurringWindowCandidates 收不到该 base
//        → 今日实例不进候选 → 不弹；而主面板 expandOccurrences 不看
//        base.isCompleted → 列表照常显示。列表可见但提醒静默 = 漏报。
//        启动路径 expiredCheckCandidates 已用独立查询绕开该位（R-1 第二轮），
//        常规路径须同构：实例级 isCompleted 才是判定标准。
//

import XCTest
import SwiftData
@testable import SwallowCalendar

@MainActor
final class ReminderPollCompletedBaseTests: XCTestCase {

    private let alertedIDsKey = "ReminderAlertService.lastAlertedEventIDs"
    private let lastCheckTimeKey = "ReminderAlertService.lastCheckTime"

    override func setUpWithError() throws {
        resetState()
    }

    override func tearDownWithError() throws {
        resetState()
    }

    /// 复位单例与持久化状态，保证用例互不污染
    private func resetState() {
        ReminderAlertService.shared.resetForTesting()
        UserDefaults.standard.removeObject(forKey: alertedIDsKey)
        UserDefaults.standard.removeObject(forKey: lastCheckTimeKey)
        ReminderAlertWindowController.shared.close()
    }

    /// 仅注册 CachedEvent 的内存 SwiftData 容器
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: CachedEvent.self, configurations: config)
    }

    /// 构造被旧版本完成操作污染的 daily 循环 base：
    /// isCompleted=true（整条置位）、无完成历史、游标停在今日实例
    private func makePollutedBase(id: String, todayStart: Date) -> CachedEvent {
        CachedEvent(
            eventID: id,
            title: "被污染的循环任务-\(id)",
            startDate: todayStart,
            endDate: todayStart.addingTimeInterval(600),
            isAllDay: false,
            calendarID: "test",
            calendarTitle: "测试日历",
            calendarColorHex: "#007AFF",
            category: .user,
            isCompleted: true,
            recurrenceType: .daily,
            originStartDate: todayStart.addingTimeInterval(-86400)
        )
    }

    /// 核心 bug：base 被污染置位（无完成历史）的循环任务，今日准点实例到期
    /// 应弹窗——列表（expandOccurrences 不看 base.isCompleted）显示该实例，
    /// 提醒路径按 base.isCompleted 过滤即与列表判定源分裂
    func testPollutedCompletedBaseRecurringStillAlerts() async throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        let context = container.mainContext
        // startDate 落在首检 90 秒窗口内（准点档 alertTime=startDate 已到）
        context.insert(makePollutedBase(id: "base-polluted", todayStart: Date().addingTimeInterval(-30)))
        try context.save()

        await ReminderAlertService.shared.runDueCheckForTesting()
        XCTAssertTrue(
            ReminderAlertWindowController.shared.isWindowVisible,
            "base 被污染置位的循环任务，今日到期实例仍应弹窗（实例级 isCompleted 才是判定标准）"
        )
    }

    /// 对照：今日实例已完成（完成历史含今日）时，污染 base 不得重复弹窗——
    /// 修复不得把「实例级已完成」的任务也弹出来
    func testPollutedBaseWithTodayOccurrenceCompletedDoesNotRealert() async throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        let context = container.mainContext
        let todayStart = Date().addingTimeInterval(-30)
        let base = makePollutedBase(id: "base-polluted-done", todayStart: todayStart)
        base.completedOccurrenceDates = [todayStart]
        context.insert(base)
        try context.save()

        await ReminderAlertService.shared.runDueCheckForTesting()
        XCTAssertFalse(
            ReminderAlertWindowController.shared.isWindowVisible,
            "今日实例已完成的污染 base 不应弹窗"
        )
    }
}
