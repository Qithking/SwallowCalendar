//
//  BackgroundSyncStartupSyncTests.swift
//  SwallowCalendarTests
//
//  bug: panel-reopen-ics-refresh——主面板每次重开都走 start() 全量同步含 ICS 网络刷新。
//  重开非数据变更事件，按 AC-3 同语义跳过 ICS（订阅按自身节奏更新：
//  首次启动全量/每小时定时器/订阅源变更通知/手动同步/缓存清空恢复均不受影响）
//

import XCTest
@testable import SwallowCalendar

@MainActor
final class BackgroundSyncStartupSyncTests: XCTestCase {

    override func tearDown() async throws {
        let service = BackgroundSyncService.shared
        service.stop()
        service.hasStartedOnce = true  // 恢复进程态：应用生命周期内启动过
        service.startupSyncAction = { includeSubscriptions in
            await BackgroundSyncService.shared.syncOnce(includeSubscriptions: includeSubscriptions)
        }
        service.lunarMirrorTopUpAction = {
            await CalendarService.shared.reconcileAllLunarMirrors()
        }
        service.lastLunarMirrorTopUpAt = nil
        service.lunarMirrorTopUpInterval = 24 * 60 * 60
    }

    // V-1：首次启动全量同步（含 ICS），重开面板跳过 ICS
    func testReopenSkipsSubscriptionRefresh() async {
        let service = BackgroundSyncService.shared
        service.hasStartedOnce = false
        var calls: [Bool] = []
        service.startupSyncAction = { includeSubscriptions in
            calls.append(includeSubscriptions)
        }
        // 补窗与本用例无关：注入空动作避免触达真实镜像对账
        service.lunarMirrorTopUpAction = {}

        await service.start()  // 首次启动
        await service.start()  // 主面板重开

        XCTAssertEqual(calls, [true, false], "首次启动全量同步，重开应跳过 ICS 订阅刷新")
    }

    // M8：启动补窗一次；同日重开不再补，超过间隔后再次补
    func testLunarMirrorTopUpRunsOncePerInterval() async {
        let service = BackgroundSyncService.shared
        var calls = 0
        service.lastLunarMirrorTopUpAt = nil
        service.lunarMirrorTopUpAction = { calls += 1 }

        let t0 = Date(timeIntervalSince1970: 1_000_000)
        await service.runLunarMirrorTopUpIfNeeded(now: t0)
        await service.runLunarMirrorTopUpIfNeeded(now: t0.addingTimeInterval(3600))
        XCTAssertEqual(calls, 1, "间隔内不重复补窗")

        await service.runLunarMirrorTopUpIfNeeded(now: t0.addingTimeInterval(24 * 3600 + 60))
        XCTAssertEqual(calls, 2, "超过间隔后补窗一次")

        service.lastLunarMirrorTopUpAt = nil
        await service.runLunarMirrorTopUpIfNeeded(now: t0)
        XCTAssertEqual(calls, 3, "重启（进程内无记录）必然补窗一次")
    }

    // M8：start() 触发补窗，面板重开同日不再补
    func testStartTriggersTopUpOnlyOncePerDay() async {
        let service = BackgroundSyncService.shared
        service.hasStartedOnce = false
        service.startupSyncAction = { _ in }
        var calls = 0
        service.lastLunarMirrorTopUpAt = nil
        service.lunarMirrorTopUpAction = { calls += 1 }

        await service.start()
        await service.start()

        XCTAssertEqual(calls, 1, "首次启动补窗，同日重开不重复")
    }
}
