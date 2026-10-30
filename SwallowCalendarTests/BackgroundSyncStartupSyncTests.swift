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
    }

    // V-1：首次启动全量同步（含 ICS），重开面板跳过 ICS
    func testReopenSkipsSubscriptionRefresh() async {
        let service = BackgroundSyncService.shared
        service.hasStartedOnce = false
        var calls: [Bool] = []
        service.startupSyncAction = { includeSubscriptions in
            calls.append(includeSubscriptions)
        }

        await service.start()  // 首次启动
        await service.start()  // 主面板重开

        XCTAssertEqual(calls, [true, false], "首次启动全量同步，重开应跳过 ICS 订阅刷新")
    }
}
