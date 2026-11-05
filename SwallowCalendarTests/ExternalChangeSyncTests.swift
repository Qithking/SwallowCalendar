//
//  ExternalChangeSyncTests.swift
//  SwallowCalendarTests
//
//  reminder-sync-completeness：外部变更（EKEventStore.changed）秒级同步测试
//  及时性：监听触发 + 2s 防抖合并（注入短防抖间隔避免单测真实等待）
//

import XCTest
import EventKit
import SwiftData
@testable import SwallowCalendar

@MainActor
final class ExternalChangeSyncTests: XCTestCase {

    /// 注入的短防抖间隔（生产为 2s）
    private static let debounceSeconds: TimeInterval = 0.2

    /// 同步动作触发计数 spy（防抖 pipeline 出口）
    private final class SyncSpy {
        var count = 0
    }

    /// 计数 spy + 调用时同步状态快照（区分「同步中被调用」与「同步结束后重试」）
    private final class RetryAwareSpy {
        var count = 0
        var calledWhileSyncing = false
    }

    // MARK: - 公共脚手架

    /// 注入短防抖间隔并复位互斥状态（各用例开头显式调用，保持 MainActor 隔离）
    private func setUpPipeline() -> BackgroundSyncService {
        let service = BackgroundSyncService.shared
        service.externalChangeDebounceSeconds = Self.debounceSeconds
        service.isSyncing = false
        // BUG-10：复位待补跑标记与重试预算，避免单例状态跨用例污染
        service.pendingExternalResync = false
        service.maxExternalSyncRetries = 10
        // 触发 CalendarService 懒加载，注册 EKEventStore.changed 监听（真实链路起点）
        _ = CalendarService.shared
        return service
    }

    /// 向 default center 模拟一次外部变更通知（macOS 上 EK 变更通知统一投递 default center）
    private func postExternalStoreChange() {
        NotificationCenter.default.post(name: .EKEventStoreChanged, object: nil)
    }

    /// 等待指定时长（放行主线程 run loop，让 MainActor 防抖任务得以执行）
    private func waitFor(seconds: TimeInterval) {
        let exp = expectation(description: "等待 \(seconds)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exp.fulfill() }
        wait(for: [exp], timeout: seconds + 2.0)
    }

    // MARK: - 及时性

    /// AC-1：单次外部变更（post EKEventStoreChanged 通知）→ 防抖后恰好触发 1 次同步
    func testSingleExternalChangeTriggersSingleSyncAfterDebounce() {
        // Given: 监听就绪 + spy 记录防抖后的同步动作
        let service = setUpPipeline()
        let spy = SyncSpy()
        service.externalSyncAction = { spy.count += 1 }

        // When: 模拟一次外部变更
        postExternalStoreChange()
        waitFor(seconds: Self.debounceSeconds * 3)

        // Then: 防抖结束后恰好触发 1 次
        XCTAssertEqual(spy.count, 1, "单次外部变更应恰好触发 1 次同步")
    }

    /// AC-2：防抖窗口内连续多次通知 → 合并为 1 次同步
    func testRapidExternalChangesMergeIntoSingleSync() {
        let service = setUpPipeline()
        let spy = SyncSpy()
        service.externalSyncAction = { spy.count += 1 }

        // When: 防抖窗口内连发 5 次通知
        for _ in 0..<5 {
            postExternalStoreChange()
        }
        waitFor(seconds: Self.debounceSeconds * 3)

        // Then: 仅触发 1 次同步
        XCTAssertEqual(spy.count, 1, "防抖窗口内连发通知应合并为 1 次同步")
    }

    // MARK: - 同步互斥重试

    /// AC-4：同步进行中（isSyncing）到达的外部变更 → 同步结束后重排一次防抖重试
    /// 基线（无重试）：防抖到期即调用动作，此刻 isSyncing 仍为 true（calledWhileSyncing=true）
    func testExternalChangeDuringSyncRetriesAfterSyncEnds() {
        let service = setUpPipeline()
        let spy = RetryAwareSpy()
        service.externalSyncAction = { [weak service] in
            spy.count += 1
            spy.calledWhileSyncing = service?.isSyncing ?? false
        }

        // Given: 模拟一次同步正在进行中（如手动同步）
        service.isSyncing = true

        // When: 同步进行中到达外部变更，0.3s（1.5 个防抖窗口）后同步结束
        postExternalStoreChange()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceSeconds * 1.5) {
            service.isSyncing = false
        }
        waitFor(seconds: Self.debounceSeconds * 5)

        // Then: 同步结束后恰好重试 1 次，且动作未在同步进行中执行
        XCTAssertEqual(spy.count, 1, "同步进行中的外部变更应在同步结束后重试，不丢失")
        XCTAssertFalse(spy.calledWhileSyncing, "同步动作不应在 isSyncing=true 时执行（应重排到同步结束后）")
    }

    // MARK: - 订阅源与提醒缓存（AC-3 / AC-5）

    /// BUG-10（触发条件）：长同步跨过全部重试窗口 → 不静默丢弃，置待补跑标记
    func testRetryBudgetExhaustedSetsPendingFlag() {
        let service = setUpPipeline()
        service.maxExternalSyncRetries = 1
        let spy = SyncSpy()
        service.externalSyncAction = { spy.count += 1 }

        // Given: 模拟长同步（整个防抖窗口内 isSyncing 恒真）
        service.isSyncing = true
        postExternalStoreChange()
        waitFor(seconds: Self.debounceSeconds * 5)

        XCTAssertEqual(spy.count, 0, "同步进行中不得执行外部同步")
        XCTAssertTrue(service.pendingExternalResync, "重试预算耗尽后必须置待补跑标记，不得静默丢弃")
    }

    /// BUG-10（消费路径）：待补跑标记在本轮 syncOnce 结束时立即执行一次（跳过 ICS）
    func testPendingResyncRunsAfterSyncEnds() async throws {
        let service = setUpPipeline()
        _ = try makeSyncContainer()
        let spy = SyncSpy()
        service.externalSyncAction = { spy.count += 1 }

        service.pendingExternalResync = true
        _ = await service.syncOnce(includeSubscriptions: false)
        // 让 defer 中派生补跑 Task 获得执行机会（MainActor 让出）
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(spy.count, 1, "同步结束后必须补跑一次被丢弃的外部变更")
        XCTAssertFalse(service.pendingExternalResync)
    }

    /// 注册三模型的内存容器并注入缓存/后台同步服务（syncOnce 链路依赖）
    private func makeSyncContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: CachedEvent.self, CalendarPreference.self, CustomCalendarSource.self,
            configurations: config
        )
        EventCacheService.shared.configure(with: container)
        BackgroundSyncService.shared.configure(with: container)
        return container
    }

    /// 插入一条订阅源缓存行
    @discardableResult
    private func insertSubscriptionRow(into context: ModelContext, eventID: String) throws -> CachedEvent {
        let row = CachedEvent(
            eventID: eventID,
            title: "订阅事件",
            startDate: Date(),
            endDate: Date(),
            isAllDay: false,
            calendarID: "ics-test",
            calendarTitle: "ICS 订阅",
            calendarColorHex: "#9C27B0",
            category: .subscription
        )
        context.insert(row)
        try context.save()
        return row
    }

    /// AC-3：外部变更同步（includeSubscriptions: false）不得触碰 ICS 订阅源缓存
    func testExternalSyncSkipsSubscriptionCache() async throws {
        let service = setUpPipeline()
        let container = try makeSyncContainer()
        let context = container.mainContext
        try insertSubscriptionRow(into: context, eventID: "sub-keep")

        // When: 外部变更触发的同步（跳过订阅源）
        let failure = await service.syncOnce(includeSubscriptions: false)

        // Then: 无错误且订阅缓存行保留
        XCTAssertNil(failure, "同步不应报错: \(failure ?? "")")
        let rows = try context.fetch(FetchDescriptor<CachedEvent>())
        XCTAssertTrue(
            rows.contains { $0.eventID == "sub-keep" },
            "外部变更同步应跳过 ICS 订阅源，订阅缓存行不得被清理"
        )
    }

    /// AC-3 反向基线：默认 syncOnce() 在无启用订阅源时清理订阅缓存行
    /// （证明跳订阅断言可区分分支执行，防止空转通过）
    func testDefaultSyncCleansSubscriptionCacheWhenNoEnabledSources() async throws {
        let service = setUpPipeline()
        let container = try makeSyncContainer()
        let context = container.mainContext
        try insertSubscriptionRow(into: context, eventID: "sub-clean")

        // When: 默认全量同步（无启用订阅源）
        let failure = await service.syncOnce()

        // Then: 订阅缓存行被清理（既有行为，回归保护）
        XCTAssertNil(failure, "同步不应报错: \(failure ?? "")")
        let rows = try context.fetch(FetchDescriptor<CachedEvent>())
        XCTAssertFalse(
            rows.contains { $0.eventID == "sub-clean" },
            "默认同步在无启用订阅源时应清理订阅缓存行"
        )
    }

    /// AC-5：提醒同步开关关闭时（测试进程默认 false），外部变更同步仍清理提醒缓存行
    func testExternalSyncClearsReminderCacheWhenSyncDisabled() async throws {
        let service = setUpPipeline()
        let container = try makeSyncContainer()
        let context = container.mainContext
        // 插入提醒缓存行（不触碰 AppSettings 避免 didSet 副作用，默认即关闭）
        let row = CachedEvent(
            eventID: "rem-1",
            title: "系统提醒",
            startDate: nil,
            endDate: nil,
            isAllDay: false,
            calendarID: "reminders",
            calendarTitle: "提醒事项",
            calendarColorHex: "#FF9500",
            isReminder: true
        )
        context.insert(row)
        try context.save()

        // When: 外部变更触发的同步
        let failure = await service.syncOnce(includeSubscriptions: false)

        // Then: 提醒缓存行被清理（开关关闭→clearRemindersCache，既有行为回归保护）
        XCTAssertNil(failure, "同步不应报错: \(failure ?? "")")
        let rows = try context.fetch(FetchDescriptor<CachedEvent>())
        XCTAssertFalse(
            rows.contains { $0.isReminder },
            "提醒同步关闭时应清理提醒缓存行"
        )
    }

    // MARK: - 提醒循环规则外部删除（bug: reminder-rule-deletion-swallowed）

    /// 构造已同步的系统循环提醒缓存行（档位来自 EK 规则映射）
    @discardableResult
    private func insertRecurringReminder(eventID: String, grade: RecurrenceType) throws -> CachedEvent {
        let row = CachedEvent(
            eventID: eventID,
            title: "测试提醒",
            startDate: Date(),
            endDate: Date(),
            isAllDay: false,
            calendarID: "reminder",
            calendarTitle: "提醒",
            calendarColorHex: "#FF9500",
            isReminder: true,
            recurrenceType: grade
        )
        EventCacheService.shared.context?.insert(row)
        try EventCacheService.shared.context?.save()
        return row
    }

    /// 构造 EK 提醒映射结果（模拟 fetchReminders 产物）
    private func makeEKReminderMap(recurrenceType: RecurrenceType, notes: String?) -> CalendarEvent {
        CalendarEvent(
            id: "test-reminder",
            title: "测试提醒",
            startDate: Date(),
            endDate: Date(),
            isAllDay: false,
            calendarID: "reminder",
            calendarTitle: "提醒",
            calendarColorHex: "#FF9500",
            category: .user,
            isCompleted: false,
            priority: 0,
            isReminder: true,
            recurrenceType: recurrenceType,
            reminderMinutes: 0,
            reminderAlarmIsAbsolute: false,
            eventColorHex: nil,
            notes: notes
        )
    }

    /// 系统原生循环提醒在系统侧删除规则（EK 映射 .none 且 notes 无本地循环标记）
    /// → 必须采纳 .none，应用不得永久滞留循环档位
    func testMergeAdoptsNoneWhenEKRuleDeletedWithoutLocalMarker() throws {
        try makeSyncContainer()
        let existing = try insertRecurringReminder(eventID: "test-reminder", grade: .daily)
        let ek = makeEKReminderMap(recurrenceType: .none, notes: nil)

        // When: 同步回流合并
        _ = EventCacheService.mergeReminderUpdate(existing: existing, ek: ek)

        // Then: 档位跟随 EK 变为非循环
        XCTAssertEqual(existing.recurrenceType, .none, "外部删除循环规则后必须采纳非循环档位")
    }

    /// 应用内设置的循环档位（EK 无规则 + notes 带本地循环标记）→ 保留缓存档位，
    /// 防止 app-recurring-grade-wiped-by-sync 回归（应用自建/应用内改循环不写 EK 规则）
    func testMergeKeepsGradeWhenLocalRecurrenceMarkerPresent() throws {
        try makeSyncContainer()
        let existing = try insertRecurringReminder(eventID: "test-reminder", grade: .daily)
        let ek = makeEKReminderMap(
            recurrenceType: .none,
            notes: "[SC_RECURRENCE_LOCAL] 备注"  // 与 EventCacheService.localRecurrenceMarker 对应
        )

        // When: 同步回流合并
        _ = EventCacheService.mergeReminderUpdate(existing: existing, ek: ek)

        // Then: 本地循环档位保留
        XCTAssertEqual(existing.recurrenceType, .daily, "本地循环标记存在时不得抹掉循环档位")
    }

    /// 对照：EK 规则仍在（映射非 .none）→ 以 EK 映射为准（既有行为回归保护）
    func testMergeAdoptsEKGradeWhenRuleStillPresent() throws {
        try makeSyncContainer()
        let existing = try insertRecurringReminder(eventID: "test-reminder", grade: .daily)
        let ek = makeEKReminderMap(recurrenceType: .weekly, notes: nil)

        // When: 同步回流合并
        _ = EventCacheService.mergeReminderUpdate(existing: existing, ek: ek)

        // Then: EK 映射档位优先
        XCTAssertEqual(existing.recurrenceType, .weekly, "EK 规则存在时应采纳映射档位")
    }
}
