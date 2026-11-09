//
//  LunarMirrorMatrixTests.swift
//  SwallowCalendarTests
//
//  S8：表驱动矩阵（载体 × 频度 × 农历 × 结束条件 × 完成态 × 存在性）。
//  期望值写在表里，新增组合优先加表行，而不是逐条补用例。
//

import XCTest
@testable import SwallowCalendar

final class LunarMirrorMatrixTests: XCTestCase {
    private var calendar: Calendar { Calendar.current }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var comps = DateComponents()
        comps.year = y
        comps.month = m
        comps.day = d
        comps.hour = 12
        return calendar.date(from: comps)!
    }

    private let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 12))!
    private let origin = Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 16, hour: 12))!
    private let current = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 12))!

    /// 系统侧已有镜像的摆放方式
    private enum ExistingPlacement {
        case none
        /// 放在第一个应存在的期次上（启用的正常场景）
        case firstDesired
        /// 放在结束条件之外的未来日期（应被规则变更删除）
        case beyondEnd
    }

    /// 一行期望产出：不适用维度用 nil，允许表比断言多
    private struct Row {
        let name: String
        let isReminder: Bool
        let frequency: RecurrenceFrequency
        let isLunar: Bool
        let end: RecurrenceEndRule
        let hasHistory: Bool
        let existing: ExistingPlacement
        let createsNonEmpty: Bool?
        let deletesExisting: Bool
        let completesExisting: Bool
        let hint: MirrorHint?
    }

    private struct Outcome {
        let plan: LunarMirrorReconcilePlan
        let existingKey: String?
    }

    private func run(_ row: Row) -> Outcome {
        let baseID = "matrix"
        let spec = RecurrenceSpec(frequency: row.frequency, interval: 1, end: row.end)
        let schedule = LunarMirrorSchedule(
            spec: spec,
            isLunar: row.isLunar,
            currentDate: current,
            origin: origin,
            validStart: nil,
            validEnd: nil,
            skipHolidays: false
        )
        let horizon = LunarMirrorPolicy.horizon(now: now, furthestMirror: nil)
        let desired = LunarMirrorPolicy.desiredDates(
            schedule: schedule,
            from: current,
            now: now,
            horizon: horizon
        )

        var existing: [ExistingLunarMirror] = []
        var existingKey: String?
        var existingDate: Date?
        switch row.existing {
        case .none:
            break
        case .firstDesired:
            existingDate = desired.first ?? date(2027, 1, 16)
        case .beyondEnd:
            existingDate = date(2027, 6, 16)
        }
        if let existingDate {
            let key = OccurrenceID.make(baseID: baseID, occurrence: existingDate)
            existingKey = key
            existing.append(ExistingLunarMirror(occurrenceID: key, date: existingDate, isCompleted: false))
        }

        // 载体差异：日历事件没有完成历史语义
        let completedDates: [Date] = (row.isReminder && row.hasHistory)
            ? [existingDate ?? date(2026, 12, 16)]
            : []

        let plan = LunarMirrorPolicy.reconcile(
            baseID: baseID,
            currentDate: current,
            origin: origin,
            specState: .valid(spec),
            isLunar: row.isLunar,
            validStart: nil,
            validEnd: nil,
            completedDates: completedDates,
            now: now,
            existing: existing,
            knownKeys: existingKey.map { [$0] } ?? [],
            suppressedKeys: []
        )
        return Outcome(plan: plan, existingKey: existingKey)
    }

    /// 主矩阵：一次锁住「建什么 / 删什么 / 标完成 / 提示什么」
    func testReconcileMatrix() {
        let rows: [Row] = [
            // 提醒 · 农历 monthly：启用、无结束
            Row(name: "reminder-monthly-lunar-open", isReminder: true, frequency: .monthly,
                isLunar: true, end: .never, hasHistory: false, existing: .firstDesired,
                createsNonEmpty: true, deletesExisting: false, completesExisting: false, hint: .systemMirrors),
            // 提醒 · 农历 monthly：应用内已完成 → 保留并标完成
            Row(name: "reminder-monthly-lunar-completed", isReminder: true, frequency: .monthly,
                isLunar: true, end: .never, hasHistory: true, existing: .firstDesired,
                createsNonEmpty: nil, deletesExisting: false, completesExisting: true, hint: .systemMirrors),
            // 事件 · 农历 monthly：事件无完成历史 → 不标完成
            Row(name: "event-monthly-lunar-completed-ignored", isReminder: false, frequency: .monthly,
                isLunar: true, end: .never, hasHistory: true, existing: .firstDesired,
                createsNonEmpty: nil, deletesExisting: false, completesExisting: false, hint: .systemMirrors),
            // 提醒 · 农历 yearly：启用、无结束、无既有镜像
            Row(name: "reminder-yearly-lunar-open", isReminder: true, frequency: .yearly,
                isLunar: true, end: .never, hasHistory: false, existing: .none,
                createsNonEmpty: true, deletesExisting: false, completesExisting: false, hint: .systemMirrors),
            // 提醒 · 农历 monthly：结束日期之后已有镜像 → 规则变更删除
            Row(name: "reminder-monthly-lunar-end-date", isReminder: true, frequency: .monthly,
                isLunar: true, end: .on(date(2026, 12, 31)), hasHistory: false, existing: .beyondEnd,
                createsNonEmpty: nil, deletesExisting: true, completesExisting: false, hint: .systemMirrors),
            // 提醒 · 农历 monthly：结束次数 1 → 窗口内无后续期次
            Row(name: "reminder-monthly-lunar-end-count", isReminder: true, frequency: .monthly,
                isLunar: true, end: .after(1), hasHistory: false, existing: .beyondEnd,
                createsNonEmpty: nil, deletesExisting: true, completesExisting: false, hint: .systemMirrors),
            // 提醒 · 非农历 monthly：公历规则自足 → 删未来旧镜像、无提示
            Row(name: "reminder-monthly-solar", isReminder: true, frequency: .monthly,
                isLunar: false, end: .never, hasHistory: false, existing: .firstDesired,
                createsNonEmpty: false, deletesExisting: true, completesExisting: false, hint: nil),
            // 提醒 · 农历 daily：频度不需要换算 → 仅应用内
            Row(name: "reminder-daily-lunar", isReminder: true, frequency: .daily,
                isLunar: true, end: .never, hasHistory: false, existing: .firstDesired,
                createsNonEmpty: false, deletesExisting: true, completesExisting: false, hint: .localOnlyFrequency),
            // 提醒 · 农历 weekly：仅应用内
            Row(name: "reminder-weekly-lunar", isReminder: true, frequency: .weekly,
                isLunar: true, end: .never, hasHistory: false, existing: .firstDesired,
                createsNonEmpty: false, deletesExisting: true, completesExisting: false, hint: .localOnlyFrequency),
            // 提醒 · 非农历 hourly：无提示、清理旧镜像
            Row(name: "reminder-hourly-solar", isReminder: true, frequency: .hourly,
                isLunar: false, end: .never, hasHistory: false, existing: .firstDesired,
                createsNonEmpty: false, deletesExisting: true, completesExisting: false, hint: nil),
            // 事件 · 非农历 monthly：清理旧镜像
            Row(name: "event-monthly-solar", isReminder: false, frequency: .monthly,
                isLunar: false, end: .never, hasHistory: false, existing: .firstDesired,
                createsNonEmpty: false, deletesExisting: true, completesExisting: false, hint: nil),
            // 事件 · 农历 monthly：启用、无既有镜像
            Row(name: "event-monthly-lunar-open", isReminder: false, frequency: .monthly,
                isLunar: true, end: .never, hasHistory: false, existing: .none,
                createsNonEmpty: true, deletesExisting: false, completesExisting: false, hint: .systemMirrors)
        ]

        for row in rows {
            let outcome = run(row)
            let plan = outcome.plan

            if let expected = row.createsNonEmpty {
                XCTAssertEqual(
                    !plan.createDates.isEmpty, expected,
                    "\(row.name)：创建产出不符合期望"
                )
            }
            if let key = outcome.existingKey {
                XCTAssertEqual(
                    plan.deleteOccurrenceIDs.contains(key), row.deletesExisting,
                    "\(row.name)：删除产出不符合期望"
                )
                XCTAssertEqual(
                    plan.completeOccurrenceIDs.contains(key), row.completesExisting,
                    "\(row.name)：完成标记不符合期望"
                )
            } else {
                XCTAssertFalse(row.deletesExisting, "\(row.name)：无既有镜像时不应有删除")
            }
            let hint = LunarMirrorPolicy.hint(isLunar: row.isLunar, spec: RecurrenceSpec(frequency: row.frequency, interval: 1))
            XCTAssertEqual(hint, row.hint, "\(row.name)：提示不符合期望")
        }
    }

    /// 存在性矩阵：孤儿删除只认完整快照；窗口态与不可用都不得产出删除
    func testPresenceMatrix() {
        struct PresenceRow {
            let name: String
            let cached: Set<String>
            let complete: Set<String>?
            let windowed: Set<String>
            let expected: Set<String>
        }
        let rows = [
            PresenceRow(name: "complete-has-base", cached: [], complete: ["b"], windowed: [], expected: []),
            PresenceRow(name: "complete-empty-orphan", cached: [], complete: [], windowed: [], expected: ["b"]),
            PresenceRow(name: "cached-kept", cached: ["b"], complete: [], windowed: [], expected: []),
            PresenceRow(name: "unavailable-skip", cached: [], complete: nil, windowed: ["b"], expected: []),
            PresenceRow(name: "windowed-only-not-deletable", cached: [], complete: nil, windowed: ["b"], expected: [])
        ]
        for row in rows {
            // 类型约束：删除接口只接受 CompletePresence?；windowed 只能等价传入 nil（不可达删除路径）
            let presence = row.complete.map { CompletePresence(ids: $0, observedAt: now) }
            XCTAssertEqual(
                LunarMirrorPolicy.orphanBaseIDs(
                    cachedBaseIDs: row.cached,
                    mirrorBaseIDs: ["b"],
                    presence: presence
                ),
                row.expected,
                row.name
            )
            // 窗口态不可达删除接口：同一份窗口数据只能等价传入 nil，不得产出任何删除
            XCTAssertEqual(
                LunarMirrorPolicy.orphanBaseIDs(
                    cachedBaseIDs: row.cached,
                    mirrorBaseIDs: ["b"],
                    presence: nil
                ),
                [],
                "\(row.name)（不可用/窗口态不得参与删除判定）"
            )
        }
    }
}
