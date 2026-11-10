//
//  DueAlertSoundTests.swift
//  SwallowCalendarTests
//
//  事项到期提示音选项测试（需求：默认无，设置后到期弹框同步播放提示音）
//

import XCTest
@testable import SwallowCalendar

class DueAlertSoundTests: XCTestCase {

    // 默认档为「无」且不映射任何系统声音（未设置设置时不产生播放行为）
    func testNoneIsFirstCaseWithNoSoundName() {
        // 字面量 .none 会被推断为 Optional.none，须写完整类型
        XCTAssertEqual(DueAlertSound.allCases.first, DueAlertSound.none)
        XCTAssertNil(DueAlertSound.none.nsSoundName)
        XCTAssertEqual(DueAlertSound.none.displayName, "无")
    }

    // 每个预设档都有非空系统声音名与显示名，rawValue 可往返解码（持久化键稳定性）
    func testEveryPresetHasSoundNameAndRoundTrips() {
        for sound in DueAlertSound.allCases where sound != .none {
            XCTAssertFalse(sound.nsSoundName?.isEmpty ?? true, "\(sound.rawValue) 缺少系统声音名")
            XCTAssertFalse(sound.displayName.isEmpty, "\(sound.rawValue) 缺少显示名")
            XCTAssertEqual(DueAlertSound(rawValue: sound.rawValue), sound, "\(sound.rawValue) 无法往返解码")
        }
    }
}
