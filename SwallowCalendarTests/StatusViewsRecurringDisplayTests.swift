//
//  StatusViewsRecurringDisplayTests.swift
//  SwallowCalendarTests
//
//  菜单弹层与桌面面板循环任务显示回归测试
//  bug: status-popover-panel-recurring-invisible——TodayTodoPopoverView 与
//  DesktopTodoPanelView 的 reload 直查 CachedEvent 主表（B-27 谓词窗口），
//  循环任务 base.startDate 为过去首实例被排除，未来 occurrence 未落库不可见；
//  期望：数据源走展开链路后窗口内含循环实例与无日期行
//

import XCTest
import SwiftData
@testable import SwallowCalendar

@MainActor
final class StatusViewsRecurringDisplayTests: XCTestCase {

    /// 仅注册 CachedEvent 的内存 SwiftData 容器，注入 EventCacheService.shared
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: CachedEvent.self, configurations: config)
    }

    private func insert(
        into context: ModelContext,
        eventID: String,
        title: String = "任务",
        startDate: Date?,
        category: EventCategory = .user,
        recurrenceType: RecurrenceType = .none
    ) throws {
        let start = startDate ?? date(2026, 10, 26, 9)
        let event = CachedEvent(
            eventID: eventID,
            title: title,
            startDate: start,
            endDate: start.addingTimeInterval(3600),
            isAllDay: false,
            calendarID: "test",
            calendarTitle: "测试日历",
            calendarColorHex: "#007AFF",
            category: category,
            recurrenceType: recurrenceType
        )
        context.insert(event)
        try context.save()
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 9) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return Calendar.current.date(from: components)!
    }

    /// 今日窗口（弹层语义）：循环任务 base 在过去，今日实例必须出现在候选中
    func testUserTodoCandidatesIncludesRecurringTodayInstance() throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        let now = date(2026, 10, 26, 14)
        let dayStart = Calendar.current.startOfDay(for: now)
        let nextDayStart = Calendar.current.date(byAdding: .day, value: 1, to: dayStart)!
        try insert(
            into: container.mainContext,
            eventID: "rec-base",
            startDate: date(2026, 10, 19),
            recurrenceType: .daily
        )

        let candidates = EventCacheService.shared.userTodoCandidates(from: dayStart, to: nextDayStart)
        XCTAssertTrue(candidates.contains { $0.eventID.contains("rec-base") && $0.isCompleted == false },
                      "今日窗口候选应包含循环任务今日实例")
        XCTAssertEqual(candidates.count, 1, "今日窗口仅应有一个循环实例（base 本体行被替换）")
    }

    /// 无日期任务行（startDate==nil）应保留在候选中（弹层原谓词明确含无时间行）
    func testUserTodoCandidatesIncludesUndatedRow() throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        let now = date(2026, 10, 26, 14)
        let dayStart = Calendar.current.startOfDay(for: now)
        let nextDayStart = Calendar.current.date(byAdding: .day, value: 1, to: dayStart)!
        try insert(into: container.mainContext, eventID: "undated", startDate: nil)

        let candidates = EventCacheService.shared.userTodoCandidates(from: dayStart, to: nextDayStart)
        XCTAssertTrue(candidates.contains { $0.eventID == "undated" }, "无日期任务行应包含在候选中")
    }

    /// 系统分类行（节气等）不进候选（两视图原谓词均限定用户分类）
    func testUserTodoCandidatesExcludesSystemCategory() throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        let now = date(2026, 10, 26, 14)
        let dayStart = Calendar.current.startOfDay(for: now)
        let nextDayStart = Calendar.current.date(byAdding: .day, value: 1, to: dayStart)!
        try insert(
            into: container.mainContext,
            eventID: "solar-term",
            title: "霜降",
            startDate: date(2026, 10, 26, 8),
            category: .system
        )

        let candidates = EventCacheService.shared.userTodoCandidates(from: dayStart, to: nextDayStart)
        XCTAssertFalse(candidates.contains { $0.eventID == "solar-term" }, "系统分类行不应进入候选")
    }
}
