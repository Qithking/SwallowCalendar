//
//  LunarMirrorPolicyTests.swift
//  SwallowCalendarTests
//
//  阶段②：LunarMirrorPolicy 作为单一判定源的守卫用例。
//  断言「新旧入口同值」（同一输入双跑对比），以及 capability / hint 同源不变量。
//

import XCTest
@testable import SwallowCalendar

final class LunarMirrorPolicyTests: XCTestCase {
    private var calendar: Calendar { Calendar.current }

    private func date(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12) -> Date {
        var comps = DateComponents()
        comps.year = y
        comps.month = m
        comps.day = d
        comps.hour = hour
        return calendar.date(from: comps)!
    }

    private func makeBase(
        spec: RecurrenceSpec?,
        isLunar: Bool,
        currentDate: Date? = nil,
        completedDates: [Date] = [],
        knownKeys: [String] = [],
        suppressedKeys: [String] = []
    ) -> LunarMirrorBase {
        LunarMirrorBase(
            baseID: "base-1",
            carrier: .reminder,
            schedule: LunarMirrorSchedule(
                spec: spec,
                isLunar: isLunar,
                currentDate: currentDate,
                origin: date(2026, 1, 1),
                validStart: nil,
                validEnd: nil,
                skipHolidays: false
            ),
            completedDates: completedDates,
            registry: MirrorRegistry(knownKeys: knownKeys, suppressedKeys: suppressedKeys),
            contentFingerprint: nil
        )
    }

    // MARK: - 1. 只有每月/每年需要公历换算镜像

    func testSupportsMirrorOnlyMonthlyAndYearly() {
        for frequency in [RecurrenceFrequency.hourly, .daily, .weekly, .monthly, .yearly] {
            let expected = frequency == .monthly || frequency == .yearly
            XCTAssertEqual(
                LunarMirrorPolicy.supportsMirror(frequency: frequency),
                expected,
                "frequency=\(frequency)"
            )
        }
    }

    // MARK: - 2. 启用镜像 = 农历 + 每月/每年

    func testIsMirrorEnabledRequiresLunarAndMirroredFrequency() {
        let monthly = RecurrenceSpec(frequency: .monthly, interval: 1)
        let daily = RecurrenceSpec(frequency: .daily, interval: 1)
        XCTAssertTrue(LunarMirrorPolicy.isMirrorEnabled(isLunar: true, spec: monthly))
        XCTAssertFalse(LunarMirrorPolicy.isMirrorEnabled(isLunar: false, spec: monthly))
        XCTAssertFalse(LunarMirrorPolicy.isMirrorEnabled(isLunar: true, spec: daily))
        XCTAssertFalse(LunarMirrorPolicy.isMirrorEnabled(isLunar: true, spec: nil))
        XCTAssertFalse(LunarMirrorPolicy.isMirrorEnabled(isLunar: true, frequency: nil))
    }

    // MARK: - 3. occurrences 转发同值

    func testOccurrencesForwardsToPolicy() {
        let spec = RecurrenceSpec(frequency: .monthly, interval: 1)
        let origin = date(2026, 3, 18)
        let lower = date(2026, 3, 17)
        let upper = date(2026, 6, 30)
        let legacy = LunarMirrorPlan.occurrences(spec: spec, origin: origin, after: lower, through: upper)
        let policy = LunarMirrorPolicy.occurrences(spec: spec, origin: origin, after: lower, through: upper)
        XCTAssertEqual(legacy, policy)
        XCTAssertFalse(policy.isEmpty, "用例前提：窗口内应有期次")
    }

    // MARK: - 4. reconcile 转发同值（含登记 / 抑制 / 指纹）

    func testReconcileForwardsToPolicyWithRegistry() {
        let spec = RecurrenceSpec(frequency: .monthly, interval: 1)
        let now = date(2026, 11, 8)
        let current = date(2026, 11, 16)
        let future = date(2026, 12, 16)
        let past = date(2026, 10, 16)
        let existing = [
            ExistingLunarMirror(
                occurrenceID: OccurrenceID.make(baseID: "base-1", occurrence: future),
                date: future,
                isCompleted: false,
                contentFingerprint: "old"
            ),
            ExistingLunarMirror(
                occurrenceID: OccurrenceID.make(baseID: "base-1", occurrence: past),
                date: past,
                isCompleted: false
            )
        ]
        let known = [
            OccurrenceID.make(baseID: "base-1", occurrence: future),
            OccurrenceID.make(baseID: "base-1", occurrence: past)
        ]
        let suppressed = [OccurrenceID.make(baseID: "base-1", occurrence: date(2027, 1, 16))]

        let legacy = LunarMirrorPlan.reconcile(
            baseID: "base-1", currentDate: current, origin: date(2026, 1, 16), spec: spec,
            isLunar: true, validStart: nil, validEnd: nil, completedDates: [],
            now: now, existing: existing, knownKeys: known, suppressedKeys: suppressed,
            expectedFingerprint: "new"
        )
        let policy = LunarMirrorPolicy.reconcile(
            baseID: "base-1", currentDate: current, origin: date(2026, 1, 16), spec: spec,
            isLunar: true, validStart: nil, validEnd: nil, completedDates: [],
            now: now, existing: existing, knownKeys: known, suppressedKeys: suppressed,
            expectedFingerprint: "new"
        )
        XCTAssertEqual(legacy, policy)
        XCTAssertFalse(policy.createDates.isEmpty, "用例前提：窗口内应有待创建期次")
    }

    // MARK: - 5. 孤儿删除键（与取消农历同一判据）

    func testOrphanDeletionKeysKeepCompletedAndPast() {
        let future = date(2026, 12, 16)
        let past = date(2026, 10, 16)
        let completedFuture = date(2027, 1, 16)
        let mirrors = [
            ExistingLunarMirror(
                occurrenceID: OccurrenceID.make(baseID: "b", occurrence: future),
                date: future, isCompleted: false
            ),
            ExistingLunarMirror(
                occurrenceID: OccurrenceID.make(baseID: "b", occurrence: past),
                date: past, isCompleted: false
            ),
            ExistingLunarMirror(
                occurrenceID: OccurrenceID.make(baseID: "b", occurrence: completedFuture),
                date: completedFuture, isCompleted: true
            )
        ]
        let now = date(2026, 11, 8)
        let expected = [OccurrenceID.make(baseID: "b", occurrence: future)]
        XCTAssertEqual(
            LunarMirrorPolicy.keysToDelete(scope: .orphan, existing: mirrors, now: now),
            expected
        )
    }

    // MARK: - 6. 取消农历：只删未来未完成，历史保留（R09）

    func testKeysToDeleteCancelOrDisableKeepsHistory() {
        let future = date(2026, 12, 16)
        let past = date(2026, 10, 16)
        let completedFuture = date(2027, 1, 16)
        let mirrors = [
            ExistingLunarMirror(
                occurrenceID: OccurrenceID.make(baseID: "b", occurrence: future),
                date: future, isCompleted: false
            ),
            ExistingLunarMirror(
                occurrenceID: OccurrenceID.make(baseID: "b", occurrence: past),
                date: past, isCompleted: false
            ),
            ExistingLunarMirror(
                occurrenceID: OccurrenceID.make(baseID: "b", occurrence: completedFuture),
                date: completedFuture, isCompleted: true
            )
        ]
        XCTAssertEqual(
            LunarMirrorPolicy.keysToDelete(scope: .cancelOrDisable, existing: mirrors, now: date(2026, 11, 8)),
            [OccurrenceID.make(baseID: "b", occurrence: future)]
        )
        // 删 base 的即时清理与取消农历共用同一判据
        XCTAssertEqual(
            LunarMirrorPolicy.keysToDelete(scope: .baseRemoved, existing: mirrors, now: date(2026, 11, 8)),
            [OccurrenceID.make(baseID: "b", occurrence: future)]
        )
    }

    // MARK: - 7. 规则变更：未来且不在新期次集合 → 删除（R10）

    func testKeysToDeleteNoLongerDesiredRemovesFutureOutsideSet() {
        let now = date(2026, 11, 8)
        let keep = date(2026, 11, 16)
        let drop = date(2026, 12, 16)
        let past = date(2026, 10, 16)
        let mirrors = [
            ExistingLunarMirror(
                occurrenceID: OccurrenceID.make(baseID: "b", occurrence: keep),
                date: keep, isCompleted: false
            ),
            ExistingLunarMirror(
                occurrenceID: OccurrenceID.make(baseID: "b", occurrence: drop),
                date: drop, isCompleted: false
            ),
            ExistingLunarMirror(
                occurrenceID: OccurrenceID.make(baseID: "b", occurrence: past),
                date: past, isCompleted: false
            )
        ]
        let desired = Set([Int(keep.timeIntervalSince1970)])
        XCTAssertEqual(
            LunarMirrorPolicy.keysToDelete(
                scope: .noLongerDesired(desiredEpochs: desired, currentEpoch: nil),
                existing: mirrors,
                now: now
            ),
            [OccurrenceID.make(baseID: "b", occurrence: drop)]
        )
    }

    // MARK: - 8. 当前期冗余：即使已过期也删除该键（R11）

    func testKeysToDeleteNoLongerDesiredRemovesRedundantCurrentEvenPast() {
        let now = date(2026, 11, 8)
        let current = date(2026, 11, 1)
        let future = date(2026, 12, 16)
        let mirrors = [
            ExistingLunarMirror(
                occurrenceID: OccurrenceID.make(baseID: "b", occurrence: current),
                date: current, isCompleted: false
            ),
            ExistingLunarMirror(
                occurrenceID: OccurrenceID.make(baseID: "b", occurrence: future),
                date: future, isCompleted: false
            )
        ]
        let desired = Set([Int(future.timeIntervalSince1970)])
        XCTAssertEqual(
            LunarMirrorPolicy.keysToDelete(
                scope: .noLongerDesired(desiredEpochs: desired, currentEpoch: Int(current.timeIntervalSince1970)),
                existing: mirrors,
                now: now
            ),
            [OccurrenceID.make(baseID: "b", occurrence: current)]
        )
    }

    // MARK: - 9. S5：规则损坏 ≠ 取消农历

    func testCorruptSpecSkipsAllMirrorChanges() {
        let now = date(2026, 11, 8)
        let future = date(2026, 12, 16)
        let key = OccurrenceID.make(baseID: "b", occurrence: future)
        let plan = LunarMirrorPolicy.reconcile(
            baseID: "b",
            currentDate: date(2026, 11, 16),
            origin: date(2026, 1, 16),
            specState: .corrupt,
            isLunar: true,
            validStart: nil,
            validEnd: nil,
            completedDates: [],
            now: now,
            existing: [
                ExistingLunarMirror(occurrenceID: key, date: future, isCompleted: false)
            ],
            knownKeys: [key],
            suppressedKeys: [],
            expectedFingerprint: "new"
        )
        // 损坏分支：不创建、不更新、不删除、不改登记（对照「取消农历」会删掉未来镜像）
        XCTAssertEqual(plan, LunarMirrorReconcilePlan())
    }

    /// S5：抑制列表损坏不得退化为空列表——该 base 本轮跳过重建，且不改写登记
    func testCorruptSuppressedKeysSkipRebuild() {
        let now = date(2026, 11, 8)
        let current = date(2026, 11, 16)
        let missingFuture = date(2026, 12, 16)
        let missingKey = OccurrenceID.make(baseID: "b", occurrence: missingFuture)
        let spec = RecurrenceSpec(frequency: .monthly, interval: 1)

        func plan(unavailable: Bool) -> LunarMirrorReconcilePlan {
            LunarMirrorPolicy.reconcile(
                baseID: "b",
                currentDate: current,
                origin: date(2026, 1, 16),
                specState: .valid(spec),
                isLunar: true,
                validStart: nil,
                validEnd: nil,
                completedDates: [],
                now: now,
                existing: [],
                knownKeys: [missingKey],
                suppressedKeys: [],
                suppressedKeysUnavailable: unavailable
            )
        }

        let normal = plan(unavailable: false)
        // 前提：正常路径会把它判定为手删（若不抑制就会被重建）
        XCTAssertEqual(normal.suppressedKeysToAdd, [missingKey])

        let corrupt = plan(unavailable: true)
        // 损坏路径：不判定手删、不重建、不产生任何抑制写入
        XCTAssertTrue(corrupt.createDates.isEmpty, "抑制列表损坏时不得重建镜像")
        XCTAssertTrue(corrupt.suppressedKeysToAdd.isEmpty)
        XCTAssertTrue(corrupt.suppressedKeysToRemove.isEmpty)
    }

    // MARK: - 10. capability 与 hint 同源不变量

    func testCapabilityAndHintShareSingleSource() {
        let monthly = RecurrenceSpec(frequency: .monthly, interval: 1)
        let daily = RecurrenceSpec(frequency: .daily, interval: 1)
        let hourly = RecurrenceSpec(frequency: .hourly, interval: 1)

        // 农历 monthly + 当前期 → 可镜像，提示走系统侧
        let lunarMonthly = makeBase(spec: monthly, isLunar: true, currentDate: date(2026, 11, 16))
        XCTAssertEqual(LunarMirrorPolicy.capability(lunarMonthly), .mirrorAvailable)
        XCTAssertEqual(LunarMirrorPolicy.hint(lunarMonthly), .systemMirrors)

        // 农历 daily → 仅应用内，提示「仅应用内生效」
        let lunarDaily = makeBase(spec: daily, isLunar: true, currentDate: date(2026, 11, 9))
        XCTAssertEqual(LunarMirrorPolicy.capability(lunarDaily), .localOnly(.frequency))
        XCTAssertEqual(LunarMirrorPolicy.hint(lunarDaily), .localOnlyFrequency)

        // 非农历 hourly → 不显示农历提示（每小时提示由频度行独立承担）
        let plainHourly = makeBase(spec: hourly, isLunar: false, currentDate: date(2026, 11, 8))
        XCTAssertNil(LunarMirrorPolicy.hint(plainHourly))

        // 非农历 monthly → 公历规则自足，无提示
        let plainMonthly = makeBase(spec: monthly, isLunar: false, currentDate: date(2026, 11, 16))
        XCTAssertEqual(LunarMirrorPolicy.capability(plainMonthly), .localOnly(.notLunar))
        XCTAssertNil(LunarMirrorPolicy.hint(plainMonthly))

        // 无规则/单期 → specMissing：开关置灰并说明，且不得宣称走系统侧
        let missing = makeBase(spec: nil, isLunar: true, currentDate: nil)
        XCTAssertEqual(LunarMirrorPolicy.capability(missing), .specMissing)
        XCTAssertEqual(LunarMirrorPolicy.hint(missing), .specMissing)

        // 同源不变量：可镜像 ⇔ 系统侧提示；反例逐条校验
        for base in [lunarMonthly, lunarDaily, plainHourly, plainMonthly, missing] {
            let mirrored = LunarMirrorPolicy.capability(base) == .mirrorAvailable
            let systemHinted = LunarMirrorPolicy.hint(base) == .systemMirrors
            XCTAssertEqual(mirrored, systemHinted)
        }
    }
}
