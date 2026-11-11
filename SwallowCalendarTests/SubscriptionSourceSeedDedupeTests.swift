//
//  SubscriptionSourceSeedDedupeTests.swift
//  SwallowCalendarTests
//
//  订阅源重复数据回归：UserDefaults seed 标记因 cfprefsd 与磁盘 plist 脱节
//  （沙盒→非沙盒迁移遗留双 Preferences 来源）被读为 false，seed 路径仅看标记
//  不查库，导致同 URL 默认订阅源被重复插入（历史 bug：设置页出现两条「重要日历」）。
//  防线：seed 前库级 URL 判重 + 启动清理历史重复源。
//

import XCTest
import SwiftData
@testable import SwallowCalendar

@MainActor
final class SubscriptionSourceSeedDedupeTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() async throws {
        try await super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: CustomCalendarSource.self, configurations: config)
        context = ModelContext(container)
    }

    // MARK: - seed 双保险判定

    /// 标记为 true（已 seed 过）→ 永不插入，即使库为空（删光不复活语义）
    func testSeedSkippedWhenFlagTrue() {
        XCTAssertFalse(CustomCalendarSource.shouldSeedDefaultSource(
            hasSeededFlag: true,
            existingURLs: []
        ))
    }

    /// 标记 false + 库无同 URL → 插入默认源
    func testSeedInsertsWhenFlagFalseAndNoExisting() {
        XCTAssertTrue(CustomCalendarSource.shouldSeedDefaultSource(
            hasSeededFlag: false,
            existingURLs: ["https://example.com/other.ics"]
        ))
    }

    /// 核心回归：标记 false（脱节丢失）但库已有同 URL → 不插入（修复前仅看标记会插入）
    func testSeedSkippedWhenFlagFalseButSameURLExists() {
        XCTAssertFalse(CustomCalendarSource.shouldSeedDefaultSource(
            hasSeededFlag: false,
            existingURLs: [CustomCalendarSource.defaultSourceURL]
        ))
    }

    // MARK: - 历史重复清理

    /// 同 URL 两条：保留启用的一条，删除关闭的（用户已开启+标重要的配置不能被清掉）
    func testDedupeKeepsEnabledOverDisabled() {
        let enabled = CustomCalendarSource(name: "重要日历", icsURL: "https://a.com/x.ics", isEnabled: true)
        let disabled = CustomCalendarSource(name: "重要日历", icsURL: "https://a.com/x.ics", isEnabled: false)

        let toRemove = CustomCalendarSource.duplicatesToRemove([enabled, disabled])

        XCTAssertEqual(toRemove.count, 1)
        XCTAssertTrue(toRemove[0] === disabled)
    }

    /// 同 URL 两条均未启用：保留标重要的那条
    func testDedupeKeepsImportantOverPlain() {
        let important = CustomCalendarSource(name: "重要日历", icsURL: "https://a.com/x.ics", isEnabled: false, isImportant: true)
        let plain = CustomCalendarSource(name: "重要日历", icsURL: "https://a.com/x.ics", isEnabled: false)

        let toRemove = CustomCalendarSource.duplicatesToRemove([important, plain])

        XCTAssertEqual(toRemove.count, 1)
        XCTAssertTrue(toRemove[0] === plain)
    }

    /// 同 URL 状态等价：仅删一条，保留先出现的
    func testDedupeKeepsFirstWhenEquivalent() {
        let first = CustomCalendarSource(name: "重要日历", icsURL: "https://a.com/x.ics")
        let second = CustomCalendarSource(name: "重要日历", icsURL: "https://a.com/x.ics")

        let toRemove = CustomCalendarSource.duplicatesToRemove([first, second])

        XCTAssertEqual(toRemove.count, 1)
        XCTAssertTrue(toRemove[0] === second)
    }

    /// 不同 URL 互不去重
    func testDedupeIgnoresDistinctURLs() {
        let a = CustomCalendarSource(name: "A", icsURL: "https://a.com/x.ics", isEnabled: true)
        let b = CustomCalendarSource(name: "B", icsURL: "https://b.com/y.ics", isEnabled: true)

        XCTAssertTrue(CustomCalendarSource.duplicatesToRemove([a, b]).isEmpty)
    }

    /// 三条同 URL：收敛为一条（保留启用+重要），删两条
    func testDedupeReducesTripleToOne() {
        let enabledImportant = CustomCalendarSource(name: "重要日历", icsURL: "https://a.com/x.ics", isEnabled: true, isImportant: true)
        let disabled1 = CustomCalendarSource(name: "重要日历", icsURL: "https://a.com/x.ics", isEnabled: false)
        let disabled2 = CustomCalendarSource(name: "重要日历", icsURL: "https://a.com/x.ics", isEnabled: false)

        let toRemove = CustomCalendarSource.duplicatesToRemove([enabledImportant, disabled1, disabled2])

        XCTAssertEqual(toRemove.count, 2)
        XCTAssertFalse(toRemove.contains { $0 === enabledImportant })
    }
}
