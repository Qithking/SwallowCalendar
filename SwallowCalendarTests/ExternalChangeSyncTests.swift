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
}
