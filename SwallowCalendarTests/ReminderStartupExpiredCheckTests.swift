//
//  ReminderStartupExpiredCheckTests.swift
//  SwallowCalendarTests
//
//  bug: main-panel-reopen-expired-popup
//  需求：应用初始启动时弹出过期提醒；显示主界面（重开主面板）时不再弹出
//  根因：主面板重开销毁并重建 SwiftUI 树 → ContentView.task 重跑
//        initializeServices → checkExpiredEvents(ignoreAlertedCache:true)
//        以启动式语义无条件弹窗
//

import XCTest
import SwiftData
@testable import SwallowCalendar

@MainActor
final class ReminderStartupExpiredCheckTests: XCTestCase {

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

    /// 第一次调用（应用初始启动语义）应弹过期提醒；
    /// 第二次调用（主面板重开 → ContentView.task 重跑）不应再弹
    func testSecondCheckExpiredEventsDoesNotPopupAgain() async throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        let context = container.mainContext
        // 未完成且已过期的用户待办（默认无提醒 → startDate 即提醒时刻，必进弹窗）
        let event = CachedEvent(
            eventID: "expired-once",
            title: "过期待办",
            startDate: Date().addingTimeInterval(-3600),
            endDate: Date().addingTimeInterval(-3500),
            isAllDay: false,
            calendarID: "test",
            calendarTitle: "测试日历",
            calendarColorHex: "#007AFF",
            category: .user
        )
        context.insert(event)
        try context.save()

        // 首次检查 → 应弹
        await ReminderAlertService.shared.checkExpiredEvents()
        XCTAssertTrue(
            ReminderAlertWindowController.shared.isWindowVisible,
            "应用初始启动时应弹出过期提醒"
        )

        // 模拟主面板关闭后重开：弹窗已关，检查再次被触发 → 不应再弹
        ReminderAlertWindowController.shared.close()
        await ReminderAlertService.shared.checkExpiredEvents()
        XCTAssertFalse(
            ReminderAlertWindowController.shared.isWindowVisible,
            "显示主界面（重开主面板）时不应再弹出过期提醒"
        )
    }
}
