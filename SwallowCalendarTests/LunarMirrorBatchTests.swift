//
//  LunarMirrorBatchTests.swift
//  SwallowCalendarTests
//
//  批量补窗的预筛 / 预取分组 / 快照 / 孤儿判定 / 内容指纹
//  对应 review-2：H-1（孤儿清理）、M-1（批量拉取）、M-2（日历迁移）、M-3（跨 await 快照）
//

import XCTest
import EventKit
import SwiftData
@testable import SwallowCalendar

final class LunarMirrorBatchTests: XCTestCase {
    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 9) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return Calendar.current.date(from: components)!
    }

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: CachedEvent.self, configurations: config)
    }

    // MARK: - 预筛矩阵（M-1）

    /// 只有「农历 + monthly/yearly」或有登记/抑制残留、或数据损坏的 base 才需要对账
    func testSnapshotPrefilterMatrix() {
        let cases: [(isLunar: Bool, frequency: RecurrenceFrequency?, registry: Bool, specCorrupt: Bool, expected: Bool)] = [
            (true, .monthly, false, false, true),
            (true, .yearly, false, false, true),
            (true, .daily, false, false, false),
            (true, .weekly, false, false, false),
            (true, .hourly, false, false, false),
            (true, nil, false, false, false),
            (false, .monthly, true, false, true),
            (false, .monthly, false, false, false),
            // S5：损坏必须进对账（走独立的损坏分支），不能被当成「无规则」
            (true, nil, false, true, true),
            (false, nil, false, true, true)
        ]
        for item in cases {
            let specState: SpecState = item.specCorrupt
                ? .corrupt
                : (item.frequency.map { .valid(RecurrenceSpec(frequency: $0, interval: 1)) } ?? .none)
            let snapshot = CalendarService.LunarMirrorBaseSnapshot(
                baseID: "base",
                isReminder: false,
                specState: specState,
                isLunar: item.isLunar,
                hasRegistry: item.registry
            )
            XCTAssertEqual(
                snapshot.needsReconcile,
                item.expected,
                "农历=\(item.isLunar) 频度=\(String(describing: item.frequency)) 登记=\(item.registry) 损坏=\(item.specCorrupt)"
            )
        }
    }

    // MARK: - S5：损坏 ≠ 清空（解码层）

    private func makeStoredEvent(_ id: String, isLunar: Bool = true) -> CachedEvent {
        CachedEvent(
            eventID: id,
            title: "损坏数据用例",
            startDate: date(2026, 1, 1),
            endDate: date(2026, 1, 1),
            isAllDay: false,
            calendarID: "reminders",
            calendarTitle: "提醒",
            calendarColorHex: "#000",
            isReminder: true,
            recurrenceType: .none,
            isLunar: isLunar
        )
    }

    /// 规则 JSON 损坏必须落在 `.corrupt`，不得降级成 `.none`（否则会被当成「取消农历」）
    @MainActor
    func testCorruptSpecJSONIsCorruptNotNone() throws {
        let container = try makeContainer()
        let event = makeStoredEvent("corrupt-spec")
        event.recurrenceSpecJSON = "{broken"
        container.mainContext.insert(event)

        XCTAssertEqual(event.recurrenceSpecState, .corrupt)
        XCTAssertNotEqual(event.recurrenceSpecState, .none)
    }

    /// 登记 / 抑制 JSON 损坏可被识别；读取仍返回空数组，但调用方必须走「跳过重建」分支
    @MainActor
    func testCorruptRegistryJSONDetectedNotTreatedAsEmpty() throws {
        let container = try makeContainer()
        let event = makeStoredEvent("corrupt-registry")
        container.mainContext.insert(event)
        // 缺省不算损坏
        XCTAssertFalse(event.mirrorKeysCorrupt)
        XCTAssertFalse(event.suppressedMirrorKeysCorrupt)

        event.mirrorKeysJSON = "{broken"
        event.suppressedMirrorKeysJSON = "[1,2"
        XCTAssertTrue(event.mirrorKeysCorrupt)
        XCTAssertTrue(event.suppressedMirrorKeysCorrupt)
        // 读取退化为空只是兼容展示；损坏标记保证对账不会把它当成「空列表」重建镜像
        XCTAssertEqual(event.mirrorKeys, [])
        XCTAssertEqual(event.suppressedMirrorKeys, [])
    }

    // MARK: - 孤儿判定（H-1）

    /// 缓存与系统完整快照任一存在 base 都保留；两侧都不存在才算孤儿
    private func presence(_ ids: Set<String>, at date: Date = Date()) -> CompletePresence {
        CompletePresence(ids: ids, observedAt: date)
    }

    func testOrphanMirrorBaseIDs() {
        // 系统侧仍有 base（缓存读失败/为空）→ 不误删
        XCTAssertEqual(
            LunarMirrorPolicy.orphanBaseIDs(
                cachedBaseIDs: [], mirrorBaseIDs: ["b1"], presence: presence(["b1"])
            ),
            []
        )
        // 缓存仍有 base → 不清
        XCTAssertEqual(
            LunarMirrorPolicy.orphanBaseIDs(
                cachedBaseIDs: ["b1"], mirrorBaseIDs: ["b1"], presence: presence([])
            ),
            []
        )
        // 两侧都不存在 → 孤儿
        XCTAssertEqual(
            LunarMirrorPolicy.orphanBaseIDs(
                cachedBaseIDs: [], mirrorBaseIDs: ["b1"], presence: presence([])
            ),
            ["b1"]
        )
        // 只判定镜像涉及的 base，无关 ID 不受影响
        XCTAssertEqual(
            LunarMirrorPolicy.orphanBaseIDs(
                cachedBaseIDs: ["b1"], mirrorBaseIDs: ["b1", "b2"], presence: presence([])
            ),
            ["b2"]
        )
    }

    /// S4：窗口快照不能进删除判定；读取失败（nil）不得等价于「系统侧为空」
    func testOrphanBaseIDsRequiresCompletePresence() {
        // 不可用 → 不产出任何孤儿（不能把读失败当成系统侧为空）
        XCTAssertEqual(
            LunarMirrorPolicy.orphanBaseIDs(
                cachedBaseIDs: [], mirrorBaseIDs: ["b1"], presence: nil
            ),
            []
        )
        // 完整快照缺该 base → 才判孤儿
        XCTAssertEqual(
            LunarMirrorPolicy.orphanBaseIDs(
                cachedBaseIDs: [], mirrorBaseIDs: ["b1"], presence: presence([])
            ),
            ["b1"]
        )
    }

    /// S4（R05/R06）：事件侧孤儿只认每日全量快照；窗口快照类型不进孤儿判定（只收 CompletePresence?）
    func testEventOrphanDeletionUsesDailyFullPresenceOnly() {
        // 窗口快照里没有 b1，但每日全量快照里存在 → 保留
        XCTAssertEqual(
            LunarMirrorPolicy.orphanBaseIDs(
                cachedBaseIDs: [], mirrorBaseIDs: ["b1"], presence: presence(["b1"])
            ),
            []
        )
        // 全量快照也确认不存在 → 才删除
        XCTAssertEqual(
            LunarMirrorPolicy.orphanBaseIDs(
                cachedBaseIDs: [], mirrorBaseIDs: ["b1"], presence: presence([])
            ),
            ["b1"]
        )
    }

    // MARK: - 内存分组等价于逐 base 过滤（M-1）

    func testGroupReminderMirrorsByBaseMatchesPerBaseFiltering() {
        let store = EKEventStore()
        let d1 = date(2026, 3, 1)
        let d2 = date(2026, 4, 1)
        let d3 = date(2026, 5, 1)

        func makeReminder(baseID: String?, occurrence: Date?) -> EKReminder {
            let reminder = EKReminder(eventStore: store)
            if let baseID, let occurrence {
                let key = CachedEvent.makeOccurrenceID(baseID: baseID, occurrence: occurrence)
                reminder.notes = LunarMirrorPlan.marker(occurrenceID: key, fingerprint: "fp")
            } else {
                reminder.notes = "普通提醒"
            }
            return reminder
        }

        let all = [
            makeReminder(baseID: "a", occurrence: d1),
            makeReminder(baseID: "a", occurrence: d2),
            makeReminder(baseID: "b", occurrence: d3),
            makeReminder(baseID: nil, occurrence: nil)
        ]
        let grouping = CalendarService.groupReminderMirrors(all)
        let groups = grouping.groups

        XCTAssertEqual(groups.count, 2, "非镜像条目不应分组")
        XCTAssertEqual(groups["a"]?.existing.count, 2)
        XCTAssertEqual(groups["b"]?.existing.count, 1)

        // 等价性：分组结果 == 旧逐条按 baseID 过滤的结果
        for (baseID, group) in groups {
            let linearKeys = Set(all.compactMap { reminder -> String? in
                guard let key = LunarMirrorPlan.occurrenceID(from: reminder.notes),
                      CachedEvent.parseOccurrenceID(key)?.baseID == baseID else { return nil }
                return key
            })
            XCTAssertEqual(Set((grouping.items[baseID] ?? [:]).keys), linearKeys, "base=\(baseID)")
            XCTAssertEqual(Set(group.existing.map(\.occurrenceID)), linearKeys, "base=\(baseID)")
        }
    }

    func testGroupEventMirrorsByBaseMatchesPerBaseFiltering() {
        let store = EKEventStore()
        let d1 = date(2026, 3, 1)
        let d2 = date(2026, 4, 1)

        func makeEvent(baseID: String?, occurrence: Date?) -> EKEvent {
            let event = EKEvent(eventStore: store)
            if let baseID, let occurrence {
                let key = CachedEvent.makeOccurrenceID(baseID: baseID, occurrence: occurrence)
                event.notes = LunarMirrorPlan.marker(occurrenceID: key, fingerprint: "fp")
            } else {
                event.notes = "普通事件"
            }
            return event
        }

        let all = [makeEvent(baseID: "a", occurrence: d1), makeEvent(baseID: "b", occurrence: d2), makeEvent(baseID: nil, occurrence: nil)]
        let grouping = CalendarService.groupEventMirrors(all)
        let groups = grouping.groups

        XCTAssertEqual(groups.count, 2)
        for (baseID, group) in groups {
            let linearKeys = Set(all.compactMap { event -> String? in
                guard let key = LunarMirrorPlan.occurrenceID(from: event.notes),
                      CachedEvent.parseOccurrenceID(key)?.baseID == baseID else { return nil }
                return key
            })
            XCTAssertEqual(Set((grouping.items[baseID] ?? [:]).keys), linearKeys, "base=\(baseID)")
        }
    }

    // MARK: - 快照（M-3）

    /// 快照是值类型：模型删除后字段仍可读，后续流程不再触碰失效对象
    func testSnapshotSurvivesModelDeletion() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let recurring = CachedEvent(
            eventID: "lunar-monthly",
            title: "农历每月",
            startDate: date(2026, 1, 1),
            endDate: date(2026, 1, 1),
            isAllDay: false,
            calendarID: "cal",
            calendarTitle: "日历",
            calendarColorHex: "#000",
            recurrenceType: .monthly,
            isLunar: true,
            recurrenceSpecJSON: RecurrenceSpec(frequency: .monthly, interval: 1).jsonString
        )
        let registryOnly = CachedEvent(
            eventID: "registry-only",
            title: "已取消农历",
            startDate: date(2026, 2, 1),
            endDate: date(2026, 2, 1),
            isAllDay: false,
            calendarID: "reminder",
            calendarTitle: "提醒",
            calendarColorHex: "#000",
            isReminder: true
        )
        registryOnly.mirrorKeys = ["registry-only|occ:1"]
        context.insert(recurring)
        context.insert(registryOnly)
        try context.save()

        let snapshots = CalendarService.makeLunarMirrorSnapshots(from: [recurring, registryOnly])
        context.delete(recurring)
        context.delete(registryOnly)
        try context.save()

        XCTAssertEqual(snapshots.map(\.baseID), ["lunar-monthly", "registry-only"])
        XCTAssertEqual(snapshots.map(\.needsReconcile), [true, true], "农历 monthly 与残留登记都需要对账")
        XCTAssertEqual(snapshots.map(\.isReminder), [false, true])
    }

    // MARK: - 内容指纹覆盖字段（M-2）

    /// 事件：换日历会改变指纹（触发迁移）；颜色等非镜像字段不改变指纹
    func testEventFingerprintTracksCalendarButIgnoresUnrelatedFields() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let event = CachedEvent(
            eventID: "event",
            title: "标题",
            startDate: date(2026, 1, 1),
            endDate: date(2026, 1, 1),
            isAllDay: false,
            calendarID: "cal-a",
            calendarTitle: "日历A",
            calendarColorHex: "#000",
            recurrenceType: .monthly,
            isLunar: true
        )
        context.insert(event)
        let baseline = CalendarService.mirrorContentFingerprint(base: event)

        event.eventColorHex = "#FFF"
        XCTAssertEqual(CalendarService.mirrorContentFingerprint(base: event), baseline, "颜色不写入镜像，不应触发更新")

        event.calendarID = "cal-b"
        XCTAssertNotEqual(CalendarService.mirrorContentFingerprint(base: event), baseline, "换日历必须触发迁移")

        event.title = "新标题"
        XCTAssertNotEqual(CalendarService.mirrorContentFingerprint(base: event), baseline)
    }

    /// 提醒：镜像固定在默认列表，日历 ID 不参与指纹；优先级/提醒偏移参与
    func testReminderFingerprintIgnoresCalendarButTracksContent() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let reminder = CachedEvent(
            eventID: "reminder",
            title: "标题",
            startDate: date(2026, 1, 1),
            endDate: date(2026, 1, 1),
            isAllDay: false,
            calendarID: "reminder-a",
            calendarTitle: "提醒A",
            calendarColorHex: "#000",
            isReminder: true,
            recurrenceType: .monthly,
            isLunar: true
        )
        context.insert(reminder)
        let baseline = CalendarService.mirrorContentFingerprint(base: reminder)

        reminder.calendarID = "reminder-b"
        XCTAssertEqual(CalendarService.mirrorContentFingerprint(base: reminder), baseline, "提醒镜像不跟随列表，指纹不含日历")

        reminder.priority = 3
        XCTAssertNotEqual(CalendarService.mirrorContentFingerprint(base: reminder), baseline)

        reminder.reminderOffsets = [0, 10]
        XCTAssertNotEqual(CalendarService.mirrorContentFingerprint(base: reminder), baseline)
    }

    // MARK: - review-3：孤儿判定来源（已拉取全量列表）

    /// 已完成/iCloud 提醒在列表中可见，但 `calendarItem(withIdentifier:)` 单点查询返回 nil；
    /// 用列表 ID 判定才不会把系统侧仍存在的本体误判成孤儿
    func testSystemBaseIDsIncludeCompletedReminderThatSingleLookupMisses() {
        let store = EKEventStore()
        let reminder = EKReminder(eventStore: store)
        reminder.title = "已完成历史"
        reminder.isCompleted = true
        let id = reminder.calendarItemIdentifier

        // 单点查询确实拿不到（模拟已完成/iCloud 场景：误判孤儿的来源）
        XCTAssertNil(store.calendarItem(withIdentifier: id))
        // 列表 ID 集合包含它 → 不判孤儿
        XCTAssertEqual(CalendarService.systemBaseIDs(reminders: [reminder]), Set([id]))
        XCTAssertEqual(
            LunarMirrorPolicy.orphanBaseIDs(
                cachedBaseIDs: [], mirrorBaseIDs: [id], presence: presence(Set([id]))
            ),
            []
        )
    }

    // MARK: - review-3：孤儿清扫保留已完成历史

    /// 与取消农历同口径：只删未完成的未来镜像；已完成、过期都保留
    func testOrphanDeletionKeepsCompletedAndPastMirrors() {
        let now = date(2026, 6, 1)
        let future = date(2026, 7, 1)
        let past = date(2026, 5, 1)
        let zeroKey = CachedEvent.makeOccurrenceID(baseID: "b", occurrence: future)
        let mirrors = [
            ExistingLunarMirror(occurrenceID: zeroKey, date: future, isCompleted: false),
            ExistingLunarMirror(
                occurrenceID: CachedEvent.makeOccurrenceID(baseID: "b", occurrence: future.addingTimeInterval(86400)),
                date: future.addingTimeInterval(86400),
                isCompleted: true
            ),
            ExistingLunarMirror(occurrenceID: CachedEvent.makeOccurrenceID(baseID: "b", occurrence: past), date: past, isCompleted: false)
        ]
        XCTAssertEqual(
            LunarMirrorPolicy.keysToDelete(scope: .orphan, existing: mirrors, now: now),
            [zeroKey]
        )
    }

    // MARK: - review-3：关闭农历后未来镜像归零

    /// 停用农历：未来未完成镜像全部删除，已完成与过期历史保留
    func testDisablingLunarDeletesOnlyFutureIncompleteMirrors() {
        let now = date(2026, 6, 1)
        let spec = RecurrenceSpec(frequency: .monthly, interval: 1)
        let future = date(2026, 7, 1)
        let past = date(2026, 5, 1)
        let completed = date(2026, 8, 1)
        let futureKey = CachedEvent.makeOccurrenceID(baseID: "b", occurrence: future)
        let pastKey = CachedEvent.makeOccurrenceID(baseID: "b", occurrence: past)
        let completedKey = CachedEvent.makeOccurrenceID(baseID: "b", occurrence: completed)
        let existing = [
            ExistingLunarMirror(occurrenceID: futureKey, date: future, isCompleted: false),
            ExistingLunarMirror(occurrenceID: pastKey, date: past, isCompleted: false),
            ExistingLunarMirror(occurrenceID: completedKey, date: completed, isCompleted: true)
        ]
        let plan = LunarMirrorPolicy.reconcile(
            baseID: "b",
            currentDate: date(2026, 4, 1),
            origin: date(2026, 1, 1),
            spec: spec,
            isLunar: false,
            validStart: nil,
            validEnd: nil,
            completedDates: [],
            now: now,
            existing: existing
        )
        XCTAssertEqual(plan.deleteOccurrenceIDs, [futureKey])
        XCTAssertTrue(plan.createDates.isEmpty)
        XCTAssertTrue(plan.completeOccurrenceIDs.isEmpty)
    }

    // MARK: - review-3：农历提示条件与判定同源

    /// 提示条件必须与 `isLocalOnly` / 镜像启用条件一致：
    /// monthly/yearly 农历 → 写系统镜像；daily/weekly 农历 → 仅应用内；非农历不显示农历提示
    func testLunarHintMatchesLocalOnlyAndMirrorEnableConditions() {
        let monthly = RecurrenceSpec(frequency: .monthly, interval: 1)
        let daily = RecurrenceSpec(frequency: .daily, interval: 1)

        XCTAssertTrue(LunarMirrorPolicy.isMirrorEnabled(isLunar: true, spec: monthly))
        XCTAssertTrue(RecurrenceEKMapper.isLocalOnly(monthly, isLunar: true))
        let monthlyHint = RecurrencePickerView.lunarSystemHint(isLunar: true, spec: monthly)
        XCTAssertNotNil(monthlyHint)
        XCTAssertTrue(monthlyHint?.contains("按公历日期创建对应提醒") == true)
        XCTAssertFalse(monthlyHint?.contains("镜像") == true, "界面文案不允许出现「镜像」")

        XCTAssertFalse(LunarMirrorPolicy.isMirrorEnabled(isLunar: true, spec: daily))
        XCTAssertTrue(RecurrenceEKMapper.isLocalOnly(daily, isLunar: true))
        let dailyHint = RecurrencePickerView.lunarSystemHint(isLunar: true, spec: daily)
        XCTAssertNotNil(dailyHint)
        XCTAssertTrue(dailyHint?.contains("仅应用内生效") == true)

        XCTAssertNil(RecurrencePickerView.lunarSystemHint(isLunar: false, spec: monthly))
        XCTAssertFalse(LunarMirrorPolicy.isMirrorEnabled(isLunar: false, spec: monthly))
        XCTAssertFalse(RecurrenceEKMapper.isLocalOnly(monthly, isLunar: false))
    }

    /// S6：无规则/单期时农历开关置灰，并给出说明（不能切了无反应）
    func testLunarToggleDisabledWhenSpecMissing() {
        XCTAssertFalse(LunarMirrorPolicy.isLunarToggleEnabled(spec: nil))
        let hint = RecurrencePickerView.lunarSystemHint(isLunar: true, spec: nil)
        XCTAssertEqual(hint, "未设置重复周期时农历不生效；请先在「重复」中选择周期")

        let monthly = RecurrenceSpec(frequency: .monthly, interval: 1)
        XCTAssertTrue(LunarMirrorPolicy.isLunarToggleEnabled(spec: monthly))
    }

    // MARK: - review-3：同 spec 打开农历也放行对账

    @MainActor
    func testTurningOnLunarWithSameSpecIsNotBlockedByGuard() throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        let spec = RecurrenceSpec(frequency: .monthly, interval: 1)
        let base = CachedEvent(
            eventID: "lunar-on",
            title: "农历每月",
            startDate: date(2026, 1, 1),
            endDate: date(2026, 1, 1),
            isAllDay: false,
            calendarID: "reminder",
            calendarTitle: "提醒",
            calendarColorHex: "#000",
            isReminder: true,
            recurrenceType: .monthly,
            isLunar: false,
            recurrenceSpecJSON: spec.jsonString
        )
        base.suppressedMirrorKeys = ["lunar-on|occ:\(Int(date(2026, 6, 1).timeIntervalSince1970))"]
        container.mainContext.insert(base)
        try container.mainContext.save()

        try CalendarService.shared.updateEventRecurrence(eventID: "lunar-on", newSpec: spec, newIsLunar: true)

        XCTAssertTrue(base.isLunar, "spec 不变时打开农历也必须放行对账")
        XCTAssertEqual(base.suppressedMirrorKeys, [], "主动改农历口径须解除手删抑制")
    }

    // MARK: - M6：取消农历的服务层入口（spec 不变也必须放行清理）

    @MainActor
    func testTurningOffLunarWithSameSpecClearsSuppressionAndFlag() throws {
        let container = try makeContainer()
        EventCacheService.shared.configure(with: container)
        let spec = RecurrenceSpec(frequency: .monthly, interval: 1)
        let base = CachedEvent(
            eventID: "lunar-off",
            title: "农历每月",
            startDate: date(2026, 1, 1),
            endDate: date(2026, 1, 1),
            isAllDay: false,
            calendarID: "reminder",
            calendarTitle: "提醒",
            calendarColorHex: "#000",
            isReminder: true,
            recurrenceType: .monthly,
            isLunar: true,
            recurrenceSpecJSON: spec.jsonString
        )
        let futureKey = CachedEvent.makeOccurrenceID(baseID: "lunar-off", occurrence: date(2026, 5, 1))
        base.mirrorKeys = [futureKey]
        base.suppressedMirrorKeys = ["lunar-off|occ:\(Int(date(2026, 6, 1).timeIntervalSince1970))"]
        container.mainContext.insert(base)
        try container.mainContext.save()

        // spec 不变，仅关闭农历：旧守卫会直接 return，导致未来镜像不清理
        try CalendarService.shared.updateEventRecurrence(eventID: "lunar-off", newSpec: spec, newIsLunar: false)

        XCTAssertFalse(base.isLunar, "农历开关必须生效")
        XCTAssertEqual(base.suppressedMirrorKeys, [], "主动改农历口径须解除手删抑制")
        XCTAssertEqual(base.mirrorKeys, [futureKey], "登记保留，交由对账按停用口径删除未来镜像")
    }
}
