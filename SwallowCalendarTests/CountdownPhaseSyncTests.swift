//
//  CountdownPhaseSyncTests.swift
//  SwallowCalendarTests
//
//  倒计时定时器整秒对齐测试（fix：菜单栏徽标与列表倒计时不同步跳动）
//  两侧独立 1s 定时器启动时刻不同 → 节拍相位错开；对齐到 wall-clock
//  整秒边界后，无论何时启动都落在同一整秒序列，跳动时刻一致
//

import XCTest
@testable import SwallowCalendar

final class CountdownPhaseSyncTests: XCTestCase {

    // MARK: - 距下一整秒间隔的数学性质

    /// 任意时刻返回值 ∈ (0, 1]：既不允许 ≤0（GCD/RunLoop 调度无效）也不允许 >1
    func testIntervalWithinBounds() {
        let epochs: [TimeInterval] = [0, 0.001, 0.2, 0.5, 0.999, 1_800_000_000, 1_800_000_000.123456]
        for epoch in epochs {
            let interval = CountdownPhaseSync.intervalToNextSecond(from: Date(timeIntervalSince1970: epoch))
            XCTAssertGreaterThan(interval, 0, "epoch=\(epoch) 间隔必须为正")
            XCTAssertLessThanOrEqual(interval, 1, "epoch=\(epoch) 间隔不得超过 1 秒")
        }
    }

    /// 已在整秒边界（小数部分 = 0）时返回 1（对齐到下一整秒）
    func testWholeSecondBoundaryReturnsOne() {
        let interval = CountdownPhaseSync.intervalToNextSecond(from: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(interval, 1, accuracy: 1e-6)
    }

    /// 小数部分 0.3 → 距下一整秒 0.7
    func testFractionalOffset() {
        let interval = CountdownPhaseSync.intervalToNextSecond(from: Date(timeIntervalSince1970: 1_800_000_000.3))
        XCTAssertEqual(interval, 0.7, accuracy: 1e-6)
    }

    // MARK: - 同步跳动的核心性质

    /// 两个启动相位不同的定时器（如相差 0.7s 启动），对齐后首个 fire
    /// 落在**同一**整秒边界——这是两侧倒计时「同步跳动」的充要条件
    func testDifferentStartTimesAlignToSameSecond() {
        let early = Date(timeIntervalSince1970: 1_800_000_000.2)
        let late = Date(timeIntervalSince1970: 1_800_000_000.9)

        let firstFire1 = early.addingTimeInterval(CountdownPhaseSync.intervalToNextSecond(from: early))
        let firstFire2 = late.addingTimeInterval(CountdownPhaseSync.intervalToNextSecond(from: late))

        // 两者首个 fire 都对齐到 epoch 1_800_000_001 整秒边界
        XCTAssertEqual(firstFire1.timeIntervalSince1970, 1_800_000_001, accuracy: 1e-6)
        XCTAssertEqual(firstFire2.timeIntervalSince1970, 1_800_000_001, accuracy: 1e-6)
    }

    /// 固定 1s 重复间隔下，对齐后的 fire 序列持续落在整秒边界（无累积漂移）
    func testFireSequenceStaysOnSecondBoundaries() {
        let start = Date(timeIntervalSince1970: 1_800_000_000.45)
        var fireDate = start.addingTimeInterval(CountdownPhaseSync.intervalToNextSecond(from: start))
        for tick in 1...5 {
            XCTAssertEqual(fireDate.timeIntervalSince1970, 1_800_000_000 + Double(tick), accuracy: 1e-6, "第 \(tick) 次 fire 偏离整秒边界")
            fireDate = fireDate.addingTimeInterval(1)
        }
    }
}
