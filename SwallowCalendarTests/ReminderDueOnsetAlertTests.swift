//
//  ReminderDueOnsetAlertTests.swift
//  SwallowCalendarTests
//
//  bug: due-reminder-onset-miss
//  需求：设置了提前提醒（offsets 不含 0 档）的事件，到事件开始时刻应再提醒一次
//        （用户澄清：提前档弹过之后，到点没有再次提醒；未设置提醒的事件
//        到点正常弹——fallback [0]，行为不对称）
//  根因：常规检查 alertTimes 仅由显式 offsets 生成，[30] 只有「开始前 30 分钟」
//        一档，事件开始时刻无档位命中 → 到点不弹
//  修复：常规检查并入隐式准点档（alertTime=startDate），与 fallback [0] 语义对齐
//

import XCTest
import SwiftData
@testable import SwallowCalendar

@MainActor
final class ReminderDueOnsetAlertTests: XCTestCase {

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

    /// 构造设置了提前 30 分钟提醒的用户分类未完成事项（offsets=[30]，不含 0 档）
    private func makeLeadEvent(id: String, start: Date) throws -> CachedEvent {
        let event = CachedEvent(
            eventID: id,
            title: "提前提醒-\(id)",
            startDate: start,
            endDate: start.addingTimeInterval(600),
            isAllDay: false,
            calendarID: "test",
            calendarTitle: "测试日历",
            calendarColorHex: "#007AFF",
            category: .user
        )
        // 经 setter 落库，维护 reminderMinutes == max(offsets) 硬不变量
        event.reminderOffsets = [30]
        return event
    }

    /// 设置提前提醒（offsets=[30]）的事项到事件开始时刻：30 档时刻（开始前 30 分钟）
    /// 已过且早于检查窗口下界，准点档（alertTime=startDate）落在窗口内 → 应弹窗
    func testLeadOffsetEventTriggersAlertAtStart() async throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        let context = container.mainContext
        // startDate 刚过（在首检 90 秒窗口内）：30 档 = now-25min 在窗口外，
        // 隐式准点档 = startDate 应触发到点提醒
        context.insert(try makeLeadEvent(id: "onset-lead", start: Date().addingTimeInterval(-10)))
        try context.save()

        await ReminderAlertService.shared.runDueCheckForTesting()
        XCTAssertTrue(
            ReminderAlertWindowController.shared.isWindowVisible,
            "设置提前提醒的事项到事件开始时刻应再次提醒（隐式准点档）"
        )
    }

    /// 对照：提前档与准点档均未到 → 不弹窗（证明判定走时间窗口，断言非恒真）
    func testLeadOffsetEventNotAlertBeforeStart() async throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        let context = container.mainContext
        // startDate = now+25min：30 档 = now-5min（窗口外）、准点档 = now+25min（未来）→ 不弹
        context.insert(try makeLeadEvent(id: "future-lead", start: Date().addingTimeInterval(25 * 60)))
        try context.save()

        await ReminderAlertService.shared.runDueCheckForTesting()
        XCTAssertFalse(
            ReminderAlertWindowController.shared.isWindowVisible,
            "提前档与准点档均未到不应弹窗"
        )
    }
}
