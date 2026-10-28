//
//  ReminderDueZeroOffsetTests.swift
//  SwallowCalendarTests
//
//  bug: due-reminder-zero-offset-miss
//  需求：到点提醒（准点档位）应弹窗——系统提醒设置准点 alarm（relativeOffset=0）
//        同步后 reminderOffsetsJSON=nil、reminderMinutes=0（extract 只收 <0 的 alarm），
//        读取侧 fallback offsets=[0]；常规定时检查 guard offset > 0 把 0 档过滤
//        → 到点不弹窗，与启动检查「未设置提醒过期弹 startDate」语义不一致
//  修复：guard offset >= 0（0 档=准点，alertTime=startDate）+ runDueCheckForTesting 测试入口
//

import XCTest
import SwiftData
@testable import SwallowCalendar

@MainActor
final class ReminderDueZeroOffsetTests: XCTestCase {

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

    /// 构造用户分类未完成事项（默认无提醒设置：reminderMinutes=0 → offsets=[0]）
    private func makeUserEvent(id: String, start: Date) -> CachedEvent {
        CachedEvent(
            eventID: id,
            title: "准点提醒-\(id)",
            startDate: start,
            endDate: start.addingTimeInterval(600),
            isAllDay: false,
            calendarID: "test",
            calendarTitle: "测试日历",
            calendarColorHex: "#007AFF",
            category: .user
        )
    }

    /// 0 档（准点提醒/未设置提醒 fallback）事项到点：常规定时检查应弹窗
    func testZeroOffsetEventTriggersDueAlert() async throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        let context = container.mainContext
        // startDate 落在首检 90 秒窗口内（lastCheckTime 已清 → windowStart = now-90s）
        context.insert(makeUserEvent(id: "due-zero", start: Date().addingTimeInterval(-30)))
        try context.save()

        await ReminderAlertService.shared.runDueCheckForTesting()
        XCTAssertTrue(
            ReminderAlertWindowController.shared.isWindowVisible,
            "0 档事项到点应弹出提醒（与启动检查过期弹窗语义一致）"
        )
    }

    /// 对照：未来事项不应弹窗（证明判定确实走时间窗口，断言非恒真）
    func testFutureEventDoesNotTriggerDueAlert() async throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        let context = container.mainContext
        context.insert(makeUserEvent(id: "future-zero", start: Date().addingTimeInterval(3600)))
        try context.save()

        await ReminderAlertService.shared.runDueCheckForTesting()
        XCTAssertFalse(
            ReminderAlertWindowController.shared.isWindowVisible,
            "未来事项不应弹窗"
        )
    }
}
