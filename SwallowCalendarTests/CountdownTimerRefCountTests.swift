//
//  CountdownTimerRefCountTests.swift
//  SwallowCalendarTests
//
//  fix: panel-countdown-frozen-on-collapse
//  同一事件可同时显示在主界面与桌面面板（CountdownTextView 三处复用，
//  以 eventID 为注册键）。主界面收起触发 onDisappear 无条件 unregister，
//  注册表必须按引用计数注销：仅当最后一个显示方注销后才移除注册，
//  否则桌面面板的倒计时因共享注册被误删而冻结
//

import XCTest
@testable import SwallowCalendar

@MainActor
final class CountdownTimerRefCountTests: XCTestCase {

    /// 排空主队列：register/unregister 经 DispatchQueue.main.async 派发，
    /// 断言前需等待闭包执行完毕
    private func drainMainQueue() {
        let drained = expectation(description: "主队列排空")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    override func tearDown() {
        super.tearDown()
        // 清理残留注册，避免测试间共享单例状态泄漏（含堆内 timer）
        for id in ["refcount-shared", "refcount-solo"] {
            CountdownTimerManager.shared.unregister(eventID: id)
        }
        drainMainQueue()
    }

    /// 核心：两处视图注册同一事件，一处注销后另一处仍应保持刷新资格
    func testPartialUnregisterKeepsSharedRegistration() {
        let manager = CountdownTimerManager.shared
        let deadline = Date().addingTimeInterval(60)

        // 模拟主界面与桌面面板同显同一事件：同 eventID 注册两次
        manager.register(eventID: "refcount-shared", deadline: deadline)
        manager.register(eventID: "refcount-shared", deadline: deadline)
        // 主界面收起：仅一处 onDisappear 注销
        manager.unregister(eventID: "refcount-shared")
        drainMainQueue()

        // 桌面面板仍在显示，倒计时必须继续刷新
        XCTAssertTrue(manager.shouldRefresh(eventID: "refcount-shared"))

        // 清理：另一处注销后注册彻底移除
        manager.unregister(eventID: "refcount-shared")
        drainMainQueue()
        XCTAssertFalse(manager.shouldRefresh(eventID: "refcount-shared"))
    }

    /// 回归护栏：单一显示方注册后完全注销，注册正确移除
    func testFullUnregisterRemovesRegistration() {
        let manager = CountdownTimerManager.shared
        let deadline = Date().addingTimeInterval(60)

        manager.register(eventID: "refcount-solo", deadline: deadline)
        drainMainQueue()
        XCTAssertTrue(manager.shouldRefresh(eventID: "refcount-solo"))

        manager.unregister(eventID: "refcount-solo")
        drainMainQueue()
        XCTAssertFalse(manager.shouldRefresh(eventID: "refcount-solo"))
    }
}
