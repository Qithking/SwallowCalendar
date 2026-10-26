//
//  StatusBarBadgeCountdownTests.swift
//  SwallowCalendarTests
//
//  菜单栏倒计时徽标回归测试
//  bug: badge-recurring-task-invisible——循环任务 base.startDate 为过去首实例，
//  徽标直接查主表被 startDate > now 排除，未来 occurrence 未落库不可见 → 徽标回退默认图标
//

import XCTest
import SwiftData
@testable import SwallowCalendar

@MainActor
final class StatusBarBadgeCountdownTests: XCTestCase {

    /// 仅注册 CachedEvent 的内存 SwiftData 容器，注入 EventCacheService.shared
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: CachedEvent.self, configurations: config)
    }

    /// 构造用户分类任务并落库
    private func insert(
        into context: ModelContext,
        eventID: String,
        startDate: Date,
        recurrenceType: RecurrenceType,
        relativeTo now: Date
    ) throws {
        let event = CachedEvent(
            eventID: eventID,
            title: "测试任务",
            startDate: startDate,
            endDate: startDate.addingTimeInterval(3600),
            isAllDay: false,
            calendarID: "test",
            calendarTitle: "测试日历",
            calendarColorHex: "#007AFF",
            category: .user,
            recurrenceType: recurrenceType
        )
        context.insert(event)
        try context.save()
    }

    /// 循环任务 base.startDate 在过去（每天 09:00，7 天前创建），
    /// 未来 occurrence 未落库——徽标倒计时必须通过展开链路看到下一实例
    func testRecurringTaskFutureOccurrenceShowsCountdown() throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        let now = Date()
        try insert(
            into: container.mainContext,
            eventID: "rec-base",
            startDate: now.addingTimeInterval(-7 * 86400),
            recurrenceType: .daily,
            relativeTo: now
        )

        // RED（修复前）：直接查主表看不到未来 occurrence → 返回 nil
        // 期望：返回下一实例（今天/明天 09:00）的倒计时文案，非 nil
        let text = StatusBarIconManager.latestCountdownText(now: now)
        XCTAssertNotNil(text, "循环任务的未来实例应参与徽标倒计时，不应回退默认图标")
        if let text {
            XCTAssertFalse(text.contains("已过期"), "未来实例倒计时不应为已过期文案，实际: \(text)")
        }
    }

    /// 对照：非循环的过去任务不参与徽标（倒计时语义只看未来）
    func testNonRecurringPastTaskNotCounted() throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        let now = Date()
        try insert(
            into: container.mainContext,
            eventID: "past-one",
            startDate: now.addingTimeInterval(-86400),
            recurrenceType: .none,
            relativeTo: now
        )

        let text = StatusBarIconManager.latestCountdownText(now: now)
        XCTAssertNil(text, "过去开始的非循环任务不应参与倒计时徽标")
    }

    /// 回归保护：普通未来任务（现有行为）仍正确返回倒计时
    func testNonRecurringFutureTaskShowsCountdown() throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        let now = Date()
        try insert(
            into: container.mainContext,
            eventID: "future-one",
            startDate: now.addingTimeInterval(2 * 3600),
            recurrenceType: .none,
            relativeTo: now
        )

        let text = StatusBarIconManager.latestCountdownText(now: now)
        XCTAssertEqual(text, "02:00:00", "未来 2 小时任务徽标应显示 02:00:00")
    }
}
