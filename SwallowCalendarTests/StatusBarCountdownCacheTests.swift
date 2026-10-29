//
//  StatusBarCountdownCacheTests.swift
//  SwallowCalendarTests
//
//  倒计时徽章查询节流缓存回归测试
//  bug: reminder-starved-by-badge-expansion——徽章每秒全量查库展开循环任务，
//  主线程被占满导致提醒检查 Timer 饿死（到点/提前档均不弹窗）；
//  缓存把查库降频到分钟边界 + 脏标记，秒 tick 纯计算重绘
//

import XCTest
import SwiftData
@testable import SwallowCalendar

@MainActor
final class StatusBarCountdownCacheTests: XCTestCase {

    /// 同一分钟内连续 tick 只查库一次，其余命中缓存
    func testSameMinuteHitsCacheWithoutRequery() {
        var cache = CountdownBadgeCache()
        var queryCount = 0
        let base = Date(timeIntervalSince1970: 1_790_000_000)

        for second in 0..<10 {
            let now = base.addingTimeInterval(TimeInterval(second))
            let start = cache.nearestStart(now: now) {
                queryCount += 1
                return base.addingTimeInterval(3600)
            }
            XCTAssertEqual(start, base.addingTimeInterval(3600))
        }
        XCTAssertEqual(queryCount, 1, "同一分钟内 10 次 tick 只应查库 1 次（原实现为 10 次）")
    }

    /// 跨分钟边界自动重查
    func testMinuteBoundaryRequeries() {
        var cache = CountdownBadgeCache()
        var queryCount = 0
        let base = Date(timeIntervalSince1970: 1_790_000_000)

        _ = cache.nearestStart(now: base) { queryCount += 1; return base }
        // +61 秒跨入下一分钟
        let next = cache.nearestStart(now: base.addingTimeInterval(61)) { queryCount += 1; return base.addingTimeInterval(120) }
        XCTAssertEqual(queryCount, 2, "跨分钟边界应重查")
        XCTAssertEqual(next, base.addingTimeInterval(120))
    }

    /// 脏标记驱动重查并自动清除（数据变更通知合并语义）
    func testDirtyFlagForcesSingleRequery() {
        var cache = CountdownBadgeCache()
        var queryCount = 0
        let base = Date(timeIntervalSince1970: 1_790_000_000)

        _ = cache.nearestStart(now: base) { queryCount += 1; return base }
        // 同一分钟内多次置脏（同步风暴）：合并为一次重查
        cache.markDirty()
        cache.markDirty()
        _ = cache.nearestStart(now: base) { queryCount += 1; return base.addingTimeInterval(60) }
        // 再次 tick：脏已清除，命中缓存
        _ = cache.nearestStart(now: base.addingTimeInterval(1)) { queryCount += 1; return nil }

        XCTAssertEqual(queryCount, 2, "多次置脏应合并为一次重查，之后恢复命中")
    }

    /// 无事项（query 返回 nil）同样缓存，避免无事项场景每秒空查
    func testNilResultAlsoCached() {
        var cache = CountdownBadgeCache()
        var queryCount = 0
        let base = Date(timeIntervalSince1970: 1_790_000_000)

        for second in 0..<5 {
            let now = base.addingTimeInterval(TimeInterval(second))
            let start = cache.nearestStart(now: now) { queryCount += 1; return nil }
            XCTAssertNil(start)
        }
        XCTAssertEqual(queryCount, 1, "无事项状态应缓存 nil，重复 tick 不空查")
    }

    /// 查库核心与文案函数语义对齐：nearestCountdownStart 的结果经格式化
    /// 即 latestCountdownText（拆分不改变对外行为）
    func testNearestCountdownStartMatchesLegacyText() throws {
        let container = try ModelContainer(
            for: CachedEvent.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        EventCacheService.shared.configure(with: container)
        let now = Date()
        let start = now.addingTimeInterval(2 * 3600)
        container.mainContext.insert(CachedEvent(
            eventID: "future-one",
            title: "测试任务",
            startDate: start,
            endDate: start.addingTimeInterval(3600),
            isAllDay: false,
            calendarID: "test",
            calendarTitle: "测试日历",
            calendarColorHex: "#007AFF",
            category: .user
        ))
        try container.mainContext.save()

        let nearest = StatusBarIconManager.nearestCountdownStart(now: now)
        XCTAssertEqual(nearest, start)
        XCTAssertEqual(
            StatusBarIconManager.latestCountdownText(now: now),
            "02:00:00"
        )
    }
}
