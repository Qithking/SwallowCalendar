//
//  CachedEventSkipHolidaysTests.swift
//  SwallowCalendarTests
//
//  t2 数据模型：CachedEvent.skipHolidays 字段（智能跳过节假日 plan 步骤①）
//

import XCTest
import SwiftData
@testable import SwallowCalendar

final class CachedEventSkipHolidaysTests: XCTestCase {

    /// 仅注册 CachedEvent 的内存 SwiftData 上下文，测试互不污染
    @MainActor
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: CachedEvent.self, configurations: config)
        return ModelContext(container)
    }

    /// 本地时区日期构造
    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return Calendar.current.date(from: components)!
    }

    private func makeEvent() -> CachedEvent {
        CachedEvent(
            eventID: UUID().uuidString,
            title: "测试任务",
            startDate: date(2026, 10, 1, 9, 30),
            endDate: date(2026, 10, 1, 9, 30),
            isAllDay: false,
            calendarID: "test",
            calendarTitle: "测试",
            calendarColorHex: "#007AFF"
        )
    }

    /// 默认不跳过节假日（存量行为不变）
    @MainActor
    func testDefaultSkipHolidaysIsFalse() {
        XCTAssertFalse(makeEvent().skipHolidays, "未勾选时默认 false")
    }

    /// skipHolidays=true 持久化往返（save 后重新 fetch 可读回）
    @MainActor
    func testSkipHolidaysPersistsAcrossSave() throws {
        let context = try makeContext()
        let event = makeEvent()
        event.skipHolidays = true
        context.insert(event)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<CachedEvent>())
        XCTAssertEqual(fetched.count, 1, "应仅有一条缓存事件")
        XCTAssertTrue(fetched[0].skipHolidays, "持久化往返后 skipHolidays 应保持 true")
    }
}
