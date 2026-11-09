//
//  LunarMirrorEKIntegrationTests.swift
//  SwallowCalendarTests
//
//  S9：推断型前提改为「授权环境可执行、无权限显式 skip」的标记用例。
//  默认不运行（避免写入用户日历）；需显式 SC_RUN_EK_INTEGRATION=1 且已授权。
//

import EventKit
import XCTest
@testable import SwallowCalendar

final class LunarMirrorEKIntegrationTests: XCTestCase {
    /// 双重开关：未显式开启 → skip，绝不静默通过
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["SC_RUN_EK_INTEGRATION"] == "1" else {
            throw XCTSkip("需显式开启：SC_RUN_EK_INTEGRATION=1（会写入并清理一条临时日历事件）")
        }
    }

    /// BYSETPOS 往返：本地方案「每月第 N 个周几」写入 EK 后读回，setPositions 必须保持
    func testBYSETPOSRoundTripThroughEventKit() throws {
        let store = EKEventStore()
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess else {
            throw XCTSkip("需要日历 fullAccess 授权；当前状态=\(status.rawValue)（请在真实授权环境运行本用例）")
        }
        guard let calendar = store.defaultCalendarForNewEvents else {
            throw XCTSkip("没有可写的默认日历，无法执行写入往返")
        }

        let spec = RecurrenceSpec(
            frequency: .monthly,
            interval: 1,
            nthWeekday: NthWeekday(nth: 2, weekday: 1)
        )
        let anchor = Date()
        guard let rule = RecurrenceEKMapper.rule(for: spec, anchor: anchor, isLunar: false) else {
            return XCTFail("非农历 monthly 必须能映射到 EK 规则")
        }

        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = "[SC_INTEGRATION] BYSETPOS round-trip"
        event.startDate = anchor
        event.endDate = anchor.addingTimeInterval(3600)
        event.addRecurrenceRule(rule)
        try store.save(event, span: .thisEvent, commit: true)
        defer { try? store.remove(event, span: .thisEvent, commit: true) }

        // EK 的 calendarItemIdentifier 对刚保存的事件可能尚未就绪，用 eventIdentifier 兜底
        let identifier = event.eventIdentifier ?? event.calendarItemIdentifier
        guard let fetched = store.calendarItem(withIdentifier: identifier) as? EKEvent else {
            throw XCTSkip("保存后未读回事件（iCloud 同步未就绪）；请稍后重跑")
        }
        let fetchedRule = try XCTUnwrap(fetched.recurrenceRules?.first, "读回的事件缺少重复规则")
        XCTAssertEqual(fetchedRule.setPositions, rule.setPositions, "BYSETPOS 往返后发生变化")
        XCTAssertEqual(fetchedRule.frequency, rule.frequency)
        XCTAssertEqual(fetchedRule.interval, rule.interval)
    }
}
