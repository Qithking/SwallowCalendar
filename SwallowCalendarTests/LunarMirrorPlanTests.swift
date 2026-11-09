//
//  LunarMirrorPlanTests.swift
//  SwallowCalendarTests
//
//  阶段①：农历 → 公历枚举边界（闰月 / 大小月 / 跨年）+ 滚动窗口 + 镜像标记
//

import XCTest
@testable import SwallowCalendar

final class LunarMirrorPlanTests: XCTestCase {
    private var calendar: Calendar { Calendar.current }

    private func date(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12) -> Date {
        var comps = DateComponents()
        comps.year = y
        comps.month = m
        comps.day = d
        comps.hour = hour
        return calendar.date(from: comps)!
    }

    private func dayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private func lunarText(_ date: Date) -> String {
        let c = Calendar(identifier: .chinese).dateComponents([.month, .day, .isLeapMonth], from: date)
        return "\(c.month ?? -1)-\(c.day ?? -1)\(c.isLeapMonth == true ? "闰" : "")"
    }

    // MARK: - 闰月（正常多出一期，不跳过）

    func testMonthlyLunarIncludesLeapMonthOccurrence() {
        // 2025-07-10 = 农历六月十六；下一期 2025-08-09 落在闰六月 → 正常生成
        let origin = date(2025, 7, 10)
        let spec = RecurrenceSpec(frequency: .monthly, interval: 1)
        let result = LunarMirrorPlan.occurrences(
            spec: spec,
            origin: origin,
            after: date(2025, 7, 9),
            through: date(2025, 10, 31)
        )
        XCTAssertEqual(result.map { dayString($0.date) }, ["2025-07-10", "2025-08-09", "2025-09-07", "2025-10-07"])
        XCTAssertEqual(result.map { lunarText($0.date) }, ["6-16", "6-16闰", "7-16", "8-16"])

        // 闰月期次与其它期次的复合键互不冲突
        let ids = result.map { CachedEvent.makeOccurrenceID(baseID: "base-1", occurrence: $0.date) }
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertNotEqual(ids[1], ids[0])

        // 同一输入重复计算幂等
        let again = LunarMirrorPlan.occurrences(
            spec: spec,
            origin: origin,
            after: date(2025, 7, 9),
            through: date(2025, 10, 31)
        )
        XCTAssertEqual(again, result)
    }

    // MARK: - 大小月（三十遇 29 天月落廿九）

    func testMonthlyLunarClampsThirtyIntoShortMonth() {
        // 2026-03-18 = 农历正月三十；下一月二月仅 29 天 → 2026-04-16 为二月廿九
        let origin = date(2026, 3, 18)
        let spec = RecurrenceSpec(frequency: .monthly, interval: 1)
        let result = LunarMirrorPlan.occurrences(
            spec: spec,
            origin: origin,
            after: date(2026, 3, 17),
            through: date(2026, 5, 31)
        )
        XCTAssertEqual(result.map { dayString($0.date) }, ["2026-03-18", "2026-04-16", "2026-05-16"])
        XCTAssertEqual(lunarText(result[0].date), "1-30")
        XCTAssertEqual(lunarText(result[1].date), "2-29", "三十遇小月由系统 Calendar 落到廿九")
        XCTAssertEqual(lunarText(result[2].date), "3-30", "下一个月恢复三十（钳制只作用于短月）")
    }

    // MARK: - 跨年（农历月跨公历年）

    func testMonthlyLunarCrossesGregorianYear() {
        // 2026-12-09 = 农历十一月一 → 十二月一（2027-01-08）→ 正月一（2027-02-06）
        let origin = date(2026, 12, 9)
        let spec = RecurrenceSpec(frequency: .monthly, interval: 1)
        let result = LunarMirrorPlan.occurrences(
            spec: spec,
            origin: origin,
            after: date(2026, 12, 8),
            through: date(2027, 2, 6)
        )
        XCTAssertEqual(result.map { dayString($0.date) }, ["2026-12-09", "2027-01-08", "2027-02-06"])
    }

    // MARK: - 每年（农历年步进）

    func testYearlyLunarKeepsLunarMonthDay() {
        let origin = date(2025, 7, 10) // 农历六月十六
        let spec = RecurrenceSpec(frequency: .yearly, interval: 1)
        let result = LunarMirrorPlan.occurrences(
            spec: spec,
            origin: origin,
            after: date(2025, 7, 9),
            through: date(2027, 8, 1)
        )
        XCTAssertEqual(result.map { dayString($0.date) }, ["2025-07-10", "2026-07-29", "2027-07-19"])
        XCTAssertEqual(result.map { lunarText($0.date) }, ["6-16", "6-16", "6-16"])
    }

    // MARK: - 滚动窗口

    func testHorizonTopsUpToTwelveMonthsWhenTailBelowThreeMonths() {
        let now = date(2026, 11, 8)
        let full = calendar.date(byAdding: .month, value: 12, to: now)!

        XCTAssertEqual(
            LunarMirrorPlan.horizon(now: now, furthestMirror: nil, calendar: calendar),
            full,
            "无镜像时首轮铺满 12 个月"
        )
        XCTAssertEqual(
            LunarMirrorPlan.horizon(now: now, furthestMirror: date(2027, 1, 8), calendar: calendar),
            full,
            "尾端不足 3 个月补满到 12 个月"
        )

        let fiveMonths = date(2027, 4, 8)
        XCTAssertEqual(
            LunarMirrorPlan.horizon(now: now, furthestMirror: fiveMonths, calendar: calendar),
            fiveMonths,
            "尾端 ≥3 个月时不额外写入"
        )
    }

    // MARK: - 镜像标记

    func testMirrorMarkerRoundTrip() {
        let occurrenceID = CachedEvent.makeOccurrenceID(baseID: "base-1", occurrence: date(2026, 11, 8))
        let notes = "农历重复 " + LunarMirrorPlan.marker(occurrenceID: occurrenceID)
        XCTAssertEqual(LunarMirrorPlan.occurrenceID(from: notes), occurrenceID)
        XCTAssertNil(LunarMirrorPlan.occurrenceID(from: "普通备注"))
        XCTAssertNil(LunarMirrorPlan.occurrenceID(from: nil))
        XCTAssertNil(LunarMirrorPlan.occurrenceID(from: LunarMirrorPlan.markerPrefix))
    }

    // MARK: - 对账计划（阶段②）

    private func mirror(_ date: Date, completed: Bool = false, fingerprint: String? = nil) -> ExistingLunarMirror {
        ExistingLunarMirror(
            occurrenceID: CachedEvent.makeOccurrenceID(baseID: "base-1", occurrence: date),
            date: date,
            isCompleted: completed,
            contentFingerprint: fingerprint
        )
    }

    func testReconcileCreatesFutureMirrorsExcludingBaseCurrent() {
        let origin = date(2025, 7, 10)
        let spec = RecurrenceSpec(frequency: .monthly, interval: 1)
        let plan = LunarMirrorPlan.reconcile(
            baseID: "base-1",
            currentDate: origin,
            origin: origin,
            spec: spec,
            isLunar: true,
            validStart: nil,
            validEnd: nil,
            completedDates: [],
            now: origin,
            existing: [],
            calendar: calendar
        )
        XCTAssertFalse(plan.createDates.contains(origin), "本体承担当前期，不重复生成")
        XCTAssertEqual(plan.createDates.first, date(2025, 8, 9), "闰月期次正常生成")
        XCTAssertEqual(Set(plan.createDates.map { Int($0.timeIntervalSince1970) }).count, plan.createDates.count)
        XCTAssertTrue(plan.deleteOccurrenceIDs.isEmpty)
    }

    func testReconcileIsIdempotentWhenMirrorsExist() {
        let origin = date(2025, 7, 10)
        let spec = RecurrenceSpec(frequency: .monthly, interval: 1)
        let first = LunarMirrorPlan.reconcile(
            baseID: "base-1",
            currentDate: origin, origin: origin, spec: spec, isLunar: true,
            validStart: nil, validEnd: nil, completedDates: [],
            now: origin, existing: [], calendar: calendar
        )
        let existing = first.createDates.map { mirror($0) }
        let keys = first.createDates.map {
            CachedEvent.makeOccurrenceID(baseID: "base-1", occurrence: $0)
        }
        let second = LunarMirrorPlan.reconcile(
            baseID: "base-1",
            currentDate: origin, origin: origin, spec: spec, isLunar: true,
            validStart: nil, validEnd: nil, completedDates: [],
            now: origin.addingTimeInterval(3600), existing: existing,
            knownKeys: keys, calendar: calendar
        )
        XCTAssertTrue(second.createDates.isEmpty, "重复同步不堆积")
        XCTAssertTrue(second.deleteOccurrenceIDs.isEmpty)
        XCTAssertTrue(second.knownKeysToAdd.isEmpty, "已登记镜像不重复收养")
    }

    func testReconcileDeletesMirrorForAdvancedCurrentDate() {
        let origin = date(2025, 7, 10)
        let advanced = date(2025, 8, 9)
        let spec = RecurrenceSpec(frequency: .monthly, interval: 1)
        let currentMirror = mirror(advanced)
        let nextMirror = mirror(date(2025, 9, 7))
        let plan = LunarMirrorPlan.reconcile(
            baseID: "base-1",
            currentDate: advanced, origin: origin, spec: spec, isLunar: true,
            validStart: nil, validEnd: nil, completedDates: [],
            now: advanced, existing: [currentMirror, nextMirror], calendar: calendar
        )
        XCTAssertTrue(plan.deleteOccurrenceIDs.contains(currentMirror.occurrenceID), "本体已推进到该期，镜像冗余")
        XCTAssertFalse(plan.deleteOccurrenceIDs.contains(nextMirror.occurrenceID))
    }

    func testReconcileMarksCompletedMirrorAndKeepsIt() {
        let origin = date(2025, 7, 10)
        let completedDate = date(2025, 9, 7)
        let spec = RecurrenceSpec(frequency: .monthly, interval: 1)
        let completedMirror = mirror(completedDate)
        let plan = LunarMirrorPlan.reconcile(
            baseID: "base-1",
            currentDate: origin, origin: origin, spec: spec, isLunar: true,
            validStart: nil, validEnd: nil, completedDates: [completedDate],
            now: origin, existing: [completedMirror], calendar: calendar
        )
        XCTAssertEqual(plan.completeOccurrenceIDs, [completedMirror.occurrenceID])
        XCTAssertFalse(plan.deleteOccurrenceIDs.contains(completedMirror.occurrenceID))
        XCTAssertFalse(plan.createDates.contains(completedDate), "已完成镜像已覆盖该期")
    }

    func testReconcileDisablingLunarDeletesFutureIncompleteOnly() {
        let origin = date(2025, 7, 10)
        let now = date(2025, 9, 1)
        let pastMirror = mirror(date(2025, 8, 9))
        let futureMirror = mirror(date(2025, 10, 7))
        let completedMirror = mirror(date(2026, 1, 8), completed: true)
        let plan = LunarMirrorPlan.reconcile(
            baseID: "base-1",
            currentDate: origin, origin: origin, spec: nil, isLunar: false,
            validStart: nil, validEnd: nil, completedDates: [],
            now: now, existing: [pastMirror, futureMirror, completedMirror], calendar: calendar
        )
        XCTAssertTrue(plan.deleteOccurrenceIDs.contains(futureMirror.occurrenceID))
        XCTAssertFalse(plan.deleteOccurrenceIDs.contains(pastMirror.occurrenceID), "已过期未完成保留")
        XCTAssertFalse(plan.deleteOccurrenceIDs.contains(completedMirror.occurrenceID), "已完成历史保留")
        XCTAssertTrue(plan.createDates.isEmpty)
    }

    func testReconcileDeletesStaleFutureMirrorAfterSpecChange() {
        let origin = date(2025, 7, 10)
        let stale = mirror(date(2025, 8, 9))
        let spec = RecurrenceSpec(frequency: .monthly, interval: 2)
        let plan = LunarMirrorPlan.reconcile(
            baseID: "base-1",
            currentDate: origin, origin: origin, spec: spec, isLunar: true,
            validStart: nil, validEnd: nil, completedDates: [],
            now: origin, existing: [stale], calendar: calendar
        )
        XCTAssertTrue(plan.deleteOccurrenceIDs.contains(stale.occurrenceID), "规则变更后过时的未来镜像")
        XCTAssertEqual(plan.createDates.first, date(2025, 9, 7), "新规则从下一期重新铺设")
    }

    func testReconcileRespectsValidityEnd() {
        let origin = date(2025, 7, 10)
        let validEnd = date(2025, 12, 31)
        let spec = RecurrenceSpec(frequency: .monthly, interval: 1)
        let plan = LunarMirrorPlan.reconcile(
            baseID: "base-1",
            currentDate: origin, origin: origin, spec: spec, isLunar: true,
            validStart: nil, validEnd: validEnd, completedDates: [],
            now: origin, existing: [], calendar: calendar
        )
        XCTAssertTrue(plan.createDates.allSatisfy { $0 <= validEnd })
    }

    // MARK: - 手删抑制（阶段③）

    /// 首轮计划 + 登记键，供抑制用例复用
    private func makeInitialPlan() -> (plan: LunarMirrorReconcilePlan, keys: [String], origin: Date) {
        let origin = date(2025, 7, 10)
        let spec = RecurrenceSpec(frequency: .monthly, interval: 1)
        let plan = LunarMirrorPlan.reconcile(
            baseID: "base-1",
            currentDate: origin, origin: origin, spec: spec, isLunar: true,
            validStart: nil, validEnd: nil, completedDates: [],
            now: origin, existing: [], calendar: calendar
        )
        let keys = plan.createDates.map {
            CachedEvent.makeOccurrenceID(baseID: "base-1", occurrence: $0)
        }
        return (plan, keys, origin)
    }

    func testManualDeletionIsSuppressedAndNotRecreated() {
        let initial = makeInitialPlan()
        let victimDate = initial.plan.createDates[1]
        let victimKey = CachedEvent.makeOccurrenceID(baseID: "base-1", occurrence: victimDate)
        let remaining = initial.plan.createDates
            .filter { $0 != victimDate }
            .map { mirror($0) }

        let plan = LunarMirrorPlan.reconcile(
            baseID: "base-1",
            currentDate: initial.origin, origin: initial.origin,
            spec: RecurrenceSpec(frequency: .monthly, interval: 1), isLunar: true,
            validStart: nil, validEnd: nil, completedDates: [],
            now: initial.origin, existing: remaining,
            knownKeys: initial.keys, suppressedKeys: [], calendar: calendar
        )
        XCTAssertTrue(plan.suppressedKeysToAdd.contains(victimKey), "登记有、系统侧无 → 判定手删")
        XCTAssertFalse(plan.createDates.contains(victimDate), "同轮对账不复活")
        XCTAssertTrue(plan.knownKeysToRemove.contains(victimKey), "抑制后移出登记，避免再次判定")
    }

    func testSuppressionClearedByRuleChangeAllowsRecreate() {
        let initial = makeInitialPlan()
        let victimDate = initial.plan.createDates[1]
        let victimKey = CachedEvent.makeOccurrenceID(baseID: "base-1", occurrence: victimDate)
        let remaining = initial.plan.createDates.filter { $0 != victimDate }.map { mirror($0) }

        // 应用内改规则后：抑制清空、登记已移除该键（模拟 updateEventRecurrence 的清除）
        let plan = LunarMirrorPlan.reconcile(
            baseID: "base-1",
            currentDate: initial.origin, origin: initial.origin,
            spec: RecurrenceSpec(frequency: .monthly, interval: 1), isLunar: true,
            validStart: nil, validEnd: nil, completedDates: [],
            now: initial.origin, existing: remaining,
            knownKeys: initial.keys.filter { $0 != victimKey },
            suppressedKeys: [], calendar: calendar
        )
        XCTAssertTrue(plan.createDates.contains(victimDate), "抑制清除后按规则重新铺设")
        XCTAssertFalse(plan.suppressedKeysToAdd.contains(victimKey))
    }

    func testSuppressionKeysDoNotLeakAcrossBases() {
        let initial = makeInitialPlan()
        let victimDate = initial.plan.createDates[1]
        let foreignKey = CachedEvent.makeOccurrenceID(baseID: "base-2", occurrence: victimDate)
        let remaining = initial.plan.createDates.map { mirror($0) }

        let plan = LunarMirrorPlan.reconcile(
            baseID: "base-1",
            currentDate: initial.origin, origin: initial.origin,
            spec: RecurrenceSpec(frequency: .monthly, interval: 1), isLunar: true,
            validStart: nil, validEnd: nil, completedDates: [],
            now: initial.origin, existing: remaining,
            knownKeys: initial.keys + [foreignKey],
            suppressedKeys: [foreignKey], calendar: calendar
        )
        XCTAssertFalse(plan.suppressedKeysToAdd.contains(foreignKey))
        XCTAssertFalse(plan.suppressedKeysToRemove.contains(foreignKey))
        XCTAssertFalse(plan.knownKeysToRemove.contains(foreignKey))
        XCTAssertTrue(plan.createDates.isEmpty, "他 base 的抑制不影响本 base")
    }

    // MARK: - M1：提醒侧 currentDate 早于 now 时只铺未来期次

    /// 提醒本体停在过去的起始期时，历史期次不应补建镜像（避免越过期越多堆得越多）
    func testDesiredDatesExcludePastOccurrencesWhenBaseCursorIsInPast() {
        let origin = date(2025, 7, 10)
        let now = date(2025, 11, 8)
        let plan = LunarMirrorPlan.reconcile(
            baseID: "base-1",
            currentDate: origin, origin: origin,
            spec: RecurrenceSpec(frequency: .monthly, interval: 1), isLunar: true,
            validStart: nil, validEnd: nil, completedDates: [],
            now: now, existing: [], calendar: calendar
        )
        XCTAssertFalse(plan.createDates.isEmpty)
        XCTAssertTrue(plan.createDates.allSatisfy { $0 > now }, "只铺 now 之后的期次")
        XCTAssertFalse(plan.createDates.contains(date(2025, 8, 9)), "已过期的历史期次不补建")
        XCTAssertFalse(plan.createDates.contains(date(2025, 10, 7)), "已过期的历史期次不补建")
    }

    /// 用户手删的「过期镜像」不得在下次对账被复活（登记移出但不写抑制）
    func testPastHandDeletedMirrorIsNotRecreated() {
        let origin = date(2025, 7, 10)
        let now = date(2025, 11, 8)
        let victimDate = date(2025, 8, 9)
        let victimKey = CachedEvent.makeOccurrenceID(baseID: "base-1", occurrence: victimDate)
        let plan = LunarMirrorPlan.reconcile(
            baseID: "base-1",
            currentDate: origin, origin: origin,
            spec: RecurrenceSpec(frequency: .monthly, interval: 1), isLunar: true,
            validStart: nil, validEnd: nil, completedDates: [],
            now: now, existing: [],
            knownKeys: [victimKey], calendar: calendar
        )
        XCTAssertFalse(plan.createDates.contains(victimDate), "过期键不补建")
        XCTAssertTrue(plan.knownKeysToRemove.contains(victimKey), "过期手删键移出登记")
        XCTAssertFalse(plan.suppressedKeysToAdd.contains(victimKey), "过期键无需抑制（抑制只对未来有意义）")
    }

    // MARK: - M4：输出严格位于 lowerBound 之后

    /// 锚点远早于下界时，枚举结果不得包含 ≤ lowerBound 的历史期次
    func testOccurrencesNeverEmitDatesAtOrBeforeLowerBound() {
        let origin = date(2000, 1, 5)
        let lower = date(2025, 7, 10)
        let upper = date(2027, 7, 10)
        for frequency in [RecurrenceFrequency.monthly, .yearly] {
            let spec = RecurrenceSpec(frequency: frequency, interval: 1)
            let result = LunarMirrorPlan.occurrences(
                spec: spec,
                origin: origin,
                after: lower,
                through: upper
            )
            XCTAssertFalse(result.isEmpty, "freq=\(frequency)")
            XCTAssertTrue(result.allSatisfy { $0.date > lower }, "freq=\(frequency) 不得产出下界及更早的期次")
            XCTAssertTrue(result.allSatisfy { $0.date <= upper }, "freq=\(frequency) 不得越过上界")
        }
    }

    // MARK: - H2：镜像内容随本体同步（指纹 → 原地更新）

    /// 标记携带指纹且不影响复合 ID 解析；旧格式标记无指纹
    func testMirrorMarkerCarriesContentFingerprint() {
        let date = date(2025, 8, 9)
        let key = CachedEvent.makeOccurrenceID(baseID: "base-1", occurrence: date)
        let marked = LunarMirrorPlan.marker(occurrenceID: key, fingerprint: "abc123")
        XCTAssertEqual(LunarMirrorPlan.occurrenceID(from: marked), key, "指纹段不污染 ID 解析")
        XCTAssertEqual(LunarMirrorPlan.contentFingerprint(from: marked), "abc123")
        XCTAssertNil(
            LunarMirrorPlan.contentFingerprint(from: LunarMirrorPlan.marker(occurrenceID: key)),
            "旧格式无指纹段"
        )
    }

    /// 本体标题/提醒/优先级变更后，保留的未来镜像原地更新，不删不重建
    func testReconcileUpdatesRetainedMirrorsWhenFingerprintDrifts() {
        let initial = makeInitialPlan()
        let existing = initial.plan.createDates.map { mirror($0, fingerprint: "old") }
        let plan = LunarMirrorPlan.reconcile(
            baseID: "base-1",
            currentDate: initial.origin, origin: initial.origin,
            spec: RecurrenceSpec(frequency: .monthly, interval: 1), isLunar: true,
            validStart: nil, validEnd: nil, completedDates: [],
            now: initial.origin.addingTimeInterval(3600), existing: existing,
            knownKeys: initial.keys, expectedFingerprint: "new", calendar: calendar
        )
        XCTAssertEqual(Set(plan.updateOccurrenceIDs), Set(initial.keys))
        XCTAssertTrue(plan.deleteOccurrenceIDs.isEmpty, "期次未变，不删除")
        XCTAssertTrue(plan.createDates.isEmpty, "已有镜像不重复创建")
    }

    /// 指纹一致时无更新动作（重复对账幂等）
    func testReconcileSkipsUpdateWhenFingerprintMatches() {
        let initial = makeInitialPlan()
        let existing = initial.plan.createDates.map { mirror($0, fingerprint: "same") }
        let plan = LunarMirrorPlan.reconcile(
            baseID: "base-1",
            currentDate: initial.origin, origin: initial.origin,
            spec: RecurrenceSpec(frequency: .monthly, interval: 1), isLunar: true,
            validStart: nil, validEnd: nil, completedDates: [],
            now: initial.origin.addingTimeInterval(3600), existing: existing,
            knownKeys: initial.keys, expectedFingerprint: "same", calendar: calendar
        )
        XCTAssertTrue(plan.updateOccurrenceIDs.isEmpty)
    }

    /// 历史镜像（无指纹）与已完成镜像都不参与内容更新
    func testReconcileUpdatesLegacyMirrorButSkipsCompleted() {
        let initial = makeInitialPlan()
        let legacy = mirror(initial.plan.createDates[0])
        let completed = mirror(initial.plan.createDates[1], completed: true, fingerprint: "old")
        let plan = LunarMirrorPlan.reconcile(
            baseID: "base-1",
            currentDate: initial.origin, origin: initial.origin,
            spec: RecurrenceSpec(frequency: .monthly, interval: 1), isLunar: true,
            validStart: nil, validEnd: nil, completedDates: [],
            now: initial.origin.addingTimeInterval(3600), existing: [legacy, completed],
            expectedFingerprint: "new", calendar: calendar
        )
        XCTAssertEqual(plan.updateOccurrenceIDs, [legacy.occurrenceID], "旧镜像补写指纹；已完成不再改内容")
    }

    /// 规则变更后将被删除的镜像不做内容更新（避免「先更新再删」的无效写入）
    func testReconcileDoesNotUpdateMirrorScheduledForDeletion() {
        let origin = date(2025, 7, 10)
        let stale = mirror(date(2025, 8, 9), fingerprint: "old")
        let plan = LunarMirrorPlan.reconcile(
            baseID: "base-1",
            currentDate: origin, origin: origin,
            spec: RecurrenceSpec(frequency: .monthly, interval: 2), isLunar: true,
            validStart: nil, validEnd: nil, completedDates: [],
            now: origin, existing: [stale],
            expectedFingerprint: "new", calendar: calendar
        )
        XCTAssertTrue(plan.deleteOccurrenceIDs.contains(stale.occurrenceID))
        XCTAssertTrue(plan.updateOccurrenceIDs.isEmpty)
    }

    // MARK: - M2：跳过节假日的期次不铺镜像

    /// 勾选跳过节假日时，注入的休日判定命中的期次不进入新建计划
    func testSkipHolidaysExcludesRestDayOccurrences() {
        let origin = date(2025, 7, 10)
        let restDay = date(2025, 9, 7)
        let cal = calendar
        let plan = LunarMirrorPlan.reconcile(
            baseID: "base-1",
            currentDate: origin, origin: origin,
            spec: RecurrenceSpec(frequency: .monthly, interval: 1), isLunar: true,
            validStart: nil, validEnd: nil, completedDates: [],
            now: origin, existing: [],
            skipHolidays: true,
            isRestDay: { cal.isDate($0, equalTo: restDay, toGranularity: .day) },
            calendar: calendar
        )
        XCTAssertTrue(plan.createDates.contains(date(2025, 8, 9)))
        XCTAssertFalse(plan.createDates.contains(restDay), "休日期次不铺镜像")
    }

    /// 已存在的未来休日镜像会被对账删除（两端口径一致，不在系统侧响铃）
    func testSkipHolidaysDeletesExistingRestDayMirror() {
        let origin = date(2025, 7, 10)
        let restDay = date(2025, 9, 7)
        let restMirror = mirror(restDay)
        let cal = calendar
        let plan = LunarMirrorPlan.reconcile(
            baseID: "base-1",
            currentDate: origin, origin: origin,
            spec: RecurrenceSpec(frequency: .monthly, interval: 1), isLunar: true,
            validStart: nil, validEnd: nil, completedDates: [],
            now: origin, existing: [restMirror],
            skipHolidays: true,
            isRestDay: { cal.isDate($0, equalTo: restDay, toGranularity: .day) },
            calendar: calendar
        )
        XCTAssertTrue(plan.deleteOccurrenceIDs.contains(restMirror.occurrenceID))
    }

    /// 未勾选跳过节假日时不做任何过滤（回归保护）
    func testNoHolidayFilterWhenSkipHolidaysOff() {
        let origin = date(2025, 7, 10)
        let plan = LunarMirrorPlan.reconcile(
            baseID: "base-1",
            currentDate: origin, origin: origin,
            spec: RecurrenceSpec(frequency: .monthly, interval: 1), isLunar: true,
            validStart: nil, validEnd: nil, completedDates: [],
            now: origin, existing: [],
            skipHolidays: false,
            isRestDay: { _ in true },
            calendar: calendar
        )
        XCTAssertFalse(plan.createDates.isEmpty)
        XCTAssertTrue(plan.createDates.contains(date(2025, 9, 7)))
    }

    // MARK: - 日历事件镜像（与提醒共用同一份计划）

    /// 日历镜像与提醒镜像共用同一套期次/复合键：同一日期只有 baseID 不同，格式与解析一致
    func testCalendarMirrorKeysUseSameOccurrenceScheme() {
        let initial = makeInitialPlan()
        let eventBaseID = "event-base"
        for date in initial.plan.createDates.prefix(3) {
            let reminderKey = CachedEvent.makeOccurrenceID(baseID: "base-1", occurrence: date)
            let eventKey = CachedEvent.makeOccurrenceID(baseID: eventBaseID, occurrence: date)

            XCTAssertEqual(CachedEvent.parseOccurrenceID(eventKey)?.occurrence, date)
            XCTAssertEqual(CachedEvent.parseOccurrenceID(eventKey)?.baseID, eventBaseID)
            XCTAssertEqual(
                LunarMirrorPlan.occurrenceID(from: LunarMirrorPlan.marker(occurrenceID: eventKey)),
                eventKey,
                "日历镜像用同一 notes 标记识别"
            )
            XCTAssertNotEqual(reminderKey, eventKey, "不同 base 的键不冲突")
        }
    }

    /// 日历镜像重复对账幂等：已有镜像（无完成态）不重建、不重复删除
    func testCalendarMirrorReconcileIsIdempotent() {
        let initial = makeInitialPlan()
        let existing = initial.plan.createDates.map { mirror($0) }
        let plan = LunarMirrorPlan.reconcile(
            baseID: "base-1",
            currentDate: initial.origin, origin: initial.origin,
            spec: RecurrenceSpec(frequency: .monthly, interval: 1), isLunar: true,
            validStart: nil, validEnd: nil, completedDates: [],
            now: initial.origin.addingTimeInterval(3600), existing: existing,
            knownKeys: initial.keys, calendar: calendar
        )
        XCTAssertTrue(plan.createDates.isEmpty)
        XCTAssertTrue(plan.deleteOccurrenceIDs.isEmpty)
        XCTAssertTrue(plan.knownKeysToAdd.isEmpty)
    }

    /// 日历事件无完成态：取消农历时只删未来镜像，历史镜像保留且再次对账无动作
    func testCalendarMirrorCleanupKeepsPastDeletesFuture() {
        let origin = date(2025, 7, 10)
        let now = date(2025, 9, 1)
        let past = mirror(date(2025, 8, 9))
        let future = mirror(date(2025, 10, 7))
        let plan = LunarMirrorPlan.reconcile(
            baseID: "base-1",
            currentDate: origin, origin: origin, spec: nil, isLunar: false,
            validStart: nil, validEnd: nil, completedDates: [],
            now: now, existing: [past, future], calendar: calendar
        )
        XCTAssertEqual(Set(plan.deleteOccurrenceIDs), [future.occurrenceID])
        XCTAssertFalse(plan.deleteOccurrenceIDs.contains(past.occurrenceID), "过期镜像保留")

        let again = LunarMirrorPlan.reconcile(
            baseID: "base-1",
            currentDate: origin, origin: origin, spec: nil, isLunar: false,
            validStart: nil, validEnd: nil, completedDates: [],
            now: now, existing: [past], calendar: calendar
        )
        XCTAssertTrue(again.deleteOccurrenceIDs.isEmpty)
        XCTAssertTrue(again.createDates.isEmpty)
    }

    /// 读回只认镜像标记：本体普通备注不会被当作镜像，避免反写 base 农历规则
    func testCalendarMirrorReadBackOnlyRecognizesMarkedNotes() {
        let eventDate = date(2025, 10, 7)
        let key = CachedEvent.makeOccurrenceID(baseID: "event-base", occurrence: eventDate)
        XCTAssertEqual(CachedEvent.parseOccurrenceID(key)?.baseID, "event-base")
        XCTAssertEqual(
            LunarMirrorPlan.occurrenceID(from: LunarMirrorPlan.marker(occurrenceID: key)),
            key
        )
        XCTAssertNil(LunarMirrorPlan.occurrenceID(from: "此事项来自SwallowCalendar应用"))
        XCTAssertNil(LunarMirrorPlan.occurrenceID(from: nil))
    }

    // MARK: - H1：镜像仅对每月/每年启用

    /// 频度 × 是否农历矩阵：仅「农历 + monthly/yearly」产生镜像计划
    func testMirrorMatrixOnlyMonthlyAndYearlyWithLunar() {
        let origin = date(2025, 7, 10)
        // now 取原点后 1 个月：保证 12 个月窗口能覆盖每年频度的首条镜像（约 +12.6 个月）
        let now = date(2025, 8, 1)
        let existing: [ExistingLunarMirror] = []
        let frequencies: [RecurrenceFrequency] = [.hourly, .daily, .weekly, .monthly, .yearly]

        for frequency in frequencies {
            let spec = RecurrenceSpec(frequency: frequency, interval: 1)
            for isLunar in [true, false] {
                let enabledByFrequency = LunarMirrorPolicy.supportsMirror(frequency: frequency)

                let occurrences = LunarMirrorPlan.occurrences(
                    spec: spec,
                    origin: origin,
                    after: origin,
                    through: date(2027, 7, 10)
                )
                let plan = LunarMirrorPlan.reconcile(
                    baseID: "matrix-base",
                    currentDate: origin,
                    origin: origin,
                    spec: spec,
                    isLunar: isLunar,
                    validStart: nil,
                    validEnd: nil,
                    completedDates: [],
                    now: now,
                    existing: existing,
                    calendar: calendar
                )

                let shouldEnumerate = enabledByFrequency
                let shouldMirror = isLunar && enabledByFrequency
                XCTAssertEqual(
                    occurrences.isEmpty, !shouldEnumerate,
                    "occurrences: freq=\(frequency) lunar=\(isLunar)"
                )
                XCTAssertEqual(
                    plan.createDates.isEmpty, !shouldMirror,
                    "reconcile: freq=\(frequency) lunar=\(isLunar)"
                )
            }
        }
    }

    /// 反向确认：每天/每周 + 农历不触发任何批量写入
    func testDailyAndWeeklyLunarProduceNoMirror() {
        for frequency in [RecurrenceFrequency.daily, .weekly] {
            let spec = RecurrenceSpec(frequency: frequency, interval: 1)
            XCTAssertFalse(LunarMirrorPolicy.supportsMirror(frequency: frequency))
            XCTAssertTrue(
                LunarMirrorPlan.occurrences(
                    spec: spec, origin: date(2025, 7, 10),
                    after: date(2025, 7, 10), through: date(2026, 7, 10)
                ).isEmpty,
                "\(frequency) + 农历不得枚举镜像期次"
            )
            XCTAssertTrue(
                LunarMirrorPlan.reconcile(
                    baseID: "daily-weekly-base",
                    currentDate: date(2025, 7, 10), origin: date(2025, 7, 10), spec: spec,
                    isLunar: true, validStart: nil, validEnd: nil, completedDates: [],
                    now: date(2025, 7, 10), existing: [], calendar: calendar
                ).createDates.isEmpty,
                "\(frequency) + 农历不得产生镜像计划"
            )
        }
    }
}
