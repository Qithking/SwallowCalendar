//
//  ReminderCacheRetentionTests.swift
//  SwallowCalendarTests
//
//  BUG-01 回归：提醒缓存整批清理不得删除用户自建提醒及其完成历史

import XCTest
import SwiftData
@testable import SwallowCalendar

@MainActor
final class ReminderCacheRetentionTests: XCTestCase {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: CachedEvent.self, configurations: config)
    }

    /// 触发条件本身：默认关闭提醒同步 → 每次 syncOnce 走 clearRemindersCache 整批清理
    func testClearRemindersCacheKeepsUserRemindersAndHistory() throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        let context = container.mainContext

        let start = Date()
        let userReminder = CachedEvent(
            eventID: "user-reminder-1",
            title: "自建提醒",
            startDate: start,
            endDate: start,
            isAllDay: false,
            calendarID: "user-calendar",
            calendarTitle: "用户",
            calendarColorHex: "#FF9500",
            category: .user,
            isReminder: true
        )
        userReminder.completedOccurrenceDates = [start]
        userReminder.originStartDate = start
        let historyBefore = userReminder.completedOccurrenceDatesJSON

        // 外部镜像提醒：由系统提醒同步写入，清理时应被删除
        let externalReminder = CachedEvent(
            eventID: "system-reminder-1",
            title: "系统提醒",
            startDate: start,
            endDate: start,
            isAllDay: false,
            calendarID: "ek-calendar",
            calendarTitle: "系统",
            calendarColorHex: "#007AFF",
            category: .system,
            isReminder: true
        )

        context.insert(userReminder)
        context.insert(externalReminder)
        try context.save()

        EventCacheService.shared.clearRemindersCache()

        let rows = try context.fetch(FetchDescriptor<CachedEvent>())
        XCTAssertTrue(rows.contains { $0.eventID == "user-reminder-1" }, "自建提醒必须保留")
        XCTAssertFalse(rows.contains { $0.eventID == "system-reminder-1" }, "外部镜像提醒仍应被清理")

        let keptUserReminder = rows.first { $0.eventID == "user-reminder-1" }
        XCTAssertEqual(keptUserReminder?.completedOccurrenceDatesJSON, historyBefore, "完成历史不得丢失")
        XCTAssertNotNil(keptUserReminder?.originStartDate, "序列锚点不得丢失")
    }
}
