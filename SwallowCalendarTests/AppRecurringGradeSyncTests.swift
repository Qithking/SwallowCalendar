//
//  AppRecurringGradeSyncTests.swift
//  SwallowCalendarTests
//
//  bug: app-recurring-grade-wiped-by-sync——应用自建循环提醒不写 EK recurrenceRules，
//  syncReminders 回流映射恒 .none，mergeReminderUpdate 无条件覆写会抹平应用循环档位，
//  导致循环展开/完成推进失效。EK 侧确有规则映射出的档位时才采纳。

import XCTest
@testable import SwallowCalendar

final class AppRecurringGradeSyncTests: XCTestCase {

    /// 共享固定日期：保证 existing 与 ek 字段逐位相等，隔离档位单一变量
    private static let sharedDate = Date(timeIntervalSince1970: 1_790_000_000)

    /// 构造既有缓存行：应用自建循环提醒（每天档）
    private func makeExisting(grade: RecurrenceType) -> CachedEvent {
        CachedEvent(
            eventID: "rem-1",
            title: "测试循环提醒",
            startDate: Self.sharedDate,
            endDate: Self.sharedDate,
            isAllDay: false,
            calendarID: "reminder",
            calendarTitle: "提醒",
            calendarColorHex: "#FF9500",
            isReminder: true,
            recurrenceType: grade
        )
    }

    /// 构造 EK 回流映射行（同 syncReminders 循环输入）
    private func makeEK(grade: RecurrenceType) -> CalendarEvent {
        CalendarEvent(
            id: "rem-1",
            title: "测试循环提醒",
            startDate: Self.sharedDate,
            endDate: Self.sharedDate,
            isAllDay: false,
            calendarID: "reminder",
            calendarTitle: "提醒",
            calendarColorHex: "#FF9500",
            category: .user,
            isCompleted: false,
            priority: 0,
            isReminder: true,
            recurrenceType: grade,
            reminderMinutes: 0,
            reminderOffsets: nil,
            reminderAlarmIsAbsolute: false,
            eventColorHex: nil
        )
    }

    // V-1：EK 无规则（应用自建循环提醒）时，缓存循环档位必须保留
    @MainActor
    func testSyncUpdateKeepsAppRecurringGradeWhenEKHasNoRule() {
        let existing = makeExisting(grade: .daily)

        EventCacheService.mergeReminderUpdate(existing: existing, ek: makeEK(grade: .none))

        XCTAssertEqual(existing.recurrenceType, .daily, "EK 无规则回流不得抹平应用自建循环档位")
    }

    // V-2：档位无变化时不得产生假变更写入（避免每次 sync 触发无谓存储保存）
    @MainActor
    func testSyncUpdateReturnsFalseWhenOnlyGradeDiffersByEKAbsence() {
        let existing = makeExisting(grade: .daily)

        let changed = EventCacheService.mergeReminderUpdate(existing: existing, ek: makeEK(grade: .none))

        XCTAssertFalse(changed, "EK 无规则且其余字段一致时，不应因档位映射差异产生假变更")
    }

    // 对照：EK 侧确有规则映射出档位时照常采纳（系统循环提醒档位以 EK 为准）
    @MainActor
    func testSyncUpdateAdoptsEKGradeWhenRuleMapped() {
        let existing = makeExisting(grade: .daily)

        let changed = EventCacheService.mergeReminderUpdate(existing: existing, ek: makeEK(grade: .weekly))

        XCTAssertTrue(changed)
        XCTAssertEqual(existing.recurrenceType, .weekly, "EK 有规则时档位以 EK 映射为准")
    }
}
