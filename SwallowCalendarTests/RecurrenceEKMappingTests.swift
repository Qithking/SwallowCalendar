//
//  RecurrenceEKMappingTests.swift
//  SwallowCalendarTests
//
//  自定义周期 → EKRecurrenceRule 逐组合字段断言 + 反向还原等价性
//

import XCTest
import EventKit
@testable import SwallowCalendar

final class RecurrenceEKMappingTests: XCTestCase {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 9))!
    }

    private let anchor = Date()

    // MARK: - 正向：九种自定义组合

    func testEveryNDays() {
        let spec = RecurrenceSpec(frequency: .daily, interval: 3)
        let rule = RecurrenceEKMapper.rule(for: spec, anchor: anchor, isLunar: false)
        XCTAssertEqual(rule?.frequency, .daily)
        XCTAssertEqual(rule?.interval, 3)
        XCTAssertNil(rule?.daysOfTheWeek)
        XCTAssertNil(rule?.daysOfTheMonth)
        XCTAssertNil(rule?.monthsOfTheYear)
        XCTAssertNil(rule?.recurrenceEnd)
        XCTAssertEqual(RecurrenceEKMapper.spec(from: rule, anchor: anchor, inferredType: .daily), spec)
    }

    func testEveryNWeeksWithWeekdays() {
        let spec = RecurrenceSpec(frequency: .weekly, interval: 2, weekdays: [2, 4, 6])
        let rule = RecurrenceEKMapper.rule(for: spec, anchor: anchor, isLunar: false)
        XCTAssertEqual(rule?.frequency, .weekly)
        XCTAssertEqual(rule?.interval, 2)
        XCTAssertEqual(rule?.daysOfTheWeek?.map { Int($0.dayOfTheWeek.rawValue) }, [2, 4, 6])
        XCTAssertEqual(rule?.daysOfTheWeek?.map { $0.weekNumber }, [0, 0, 0])
        XCTAssertEqual(RecurrenceEKMapper.spec(from: rule, anchor: anchor, inferredType: .weekly), spec)
    }

    func testEveryNMonthsWithMonthDay() {
        let spec = RecurrenceSpec(frequency: .monthly, interval: 3, monthDay: 31)
        let rule = RecurrenceEKMapper.rule(for: spec, anchor: anchor, isLunar: false)
        XCTAssertEqual(rule?.frequency, .monthly)
        XCTAssertEqual(rule?.interval, 3)
        XCTAssertEqual(rule?.daysOfTheMonth?.map { $0.intValue }, [31])
        XCTAssertNil(rule?.monthsOfTheYear)
        XCTAssertEqual(RecurrenceEKMapper.spec(from: rule, anchor: anchor, inferredType: .monthly), spec)
    }

    func testEveryMonthNthWeekdayIncludingLast() {
        let second = RecurrenceSpec(frequency: .monthly, interval: 1, nthWeekday: NthWeekday(nth: 2, weekday: 3))
        let secondRule = RecurrenceEKMapper.rule(for: second, anchor: anchor, isLunar: false)
        XCTAssertEqual(secondRule?.frequency, .monthly)
        // BYDAY 只带星期，第几个由 BYSETPOS 表达
        XCTAssertEqual(secondRule?.daysOfTheWeek?.first?.weekNumber, 0)
        XCTAssertEqual(secondRule?.daysOfTheWeek?.first?.dayOfTheWeek.rawValue, 3)
        XCTAssertEqual(secondRule?.setPositions?.map { $0.intValue }, [2])
        XCTAssertEqual(RecurrenceEKMapper.spec(from: secondRule, anchor: anchor, inferredType: .monthly), second)

        let last = RecurrenceSpec(frequency: .monthly, interval: 2, nthWeekday: NthWeekday(nth: -1, weekday: 6))
        let lastRule = RecurrenceEKMapper.rule(for: last, anchor: anchor, isLunar: false)
        XCTAssertEqual(lastRule?.setPositions?.map { $0.intValue }, [-1])
        XCTAssertEqual(RecurrenceEKMapper.spec(from: lastRule, anchor: anchor, inferredType: .monthly), last)
    }

    func testEveryYearOnSpecifiedMonthAndDay() {
        let spec = RecurrenceSpec(frequency: .yearly, interval: 1, monthDay: 15, months: [6])
        let rule = RecurrenceEKMapper.rule(for: spec, anchor: anchor, isLunar: false)
        XCTAssertEqual(rule?.frequency, .yearly)
        XCTAssertEqual(rule?.monthsOfTheYear?.map { $0.intValue }, [6])
        XCTAssertEqual(rule?.daysOfTheMonth?.map { $0.intValue }, [15])
        XCTAssertEqual(RecurrenceEKMapper.spec(from: rule, anchor: anchor, inferredType: .yearly), spec)
    }

    func testEveryNYears() {
        let spec = RecurrenceSpec(frequency: .yearly, interval: 4, monthDay: 15, months: [6])
        let rule = RecurrenceEKMapper.rule(for: spec, anchor: anchor, isLunar: false)
        XCTAssertEqual(rule?.frequency, .yearly)
        XCTAssertEqual(rule?.interval, 4)
        XCTAssertEqual(RecurrenceEKMapper.spec(from: rule, anchor: anchor, inferredType: .yearly), spec)
    }

    func testEndOnDate() {
        var spec = RecurrenceSpec(frequency: .daily, interval: 1)
        spec.end = .on(date(2031, 1, 1))
        let rule = RecurrenceEKMapper.rule(for: spec, anchor: anchor, isLunar: false)
        XCTAssertEqual(rule?.recurrenceEnd?.endDate, date(2031, 1, 1))
        let restored = RecurrenceEKMapper.spec(from: rule, anchor: anchor, inferredType: .daily)
        XCTAssertEqual(restored?.end.mode, .date)
        XCTAssertEqual(restored?.end.date, date(2031, 1, 1))
    }

    func testEndAfterCount() {
        var spec = RecurrenceSpec(frequency: .weekly, interval: 2, weekdays: [2, 4])
        spec.end = .after(5)
        let rule = RecurrenceEKMapper.rule(for: spec, anchor: anchor, isLunar: false)
        XCTAssertEqual(rule?.recurrenceEnd?.occurrenceCount, 5)
        XCTAssertNil(rule?.recurrenceEnd?.endDate)
        let restored = RecurrenceEKMapper.spec(from: rule, anchor: anchor, inferredType: .weekly)
        XCTAssertEqual(restored?.end.mode, .count)
        XCTAssertEqual(restored?.end.count, 5)
        XCTAssertEqual(restored?.interval, 2)
        XCTAssertEqual(restored?.weekdays, [2, 4])
    }

    func testSetPositionsCarriesNthSemantics() {
        // 第 N 个周几在 EK 侧既可由 weekNumber 表达，也应由 setPositions 显式指定
        let spec = RecurrenceSpec(frequency: .monthly, interval: 1, nthWeekday: NthWeekday(nth: -1, weekday: 6))
        let rule = RecurrenceEKMapper.rule(for: spec, anchor: anchor, isLunar: false)
        XCTAssertEqual(rule?.setPositions?.map { $0.intValue }, [-1])
    }

    // MARK: - 界面提示条件：与映射层共用 isLocalOnly

    func testCustomSpecsAreNotLocalOnly() {
        // 这些就是「周期→自定义」可展开的配置，界面不应再出现「仅应用内生效」提示
        let specs: [RecurrenceSpec] = [
            RecurrenceSpec(frequency: .daily, interval: 2),
            RecurrenceSpec(frequency: .weekly, interval: 2, weekdays: [2, 4, 6]),
            RecurrenceSpec(frequency: .monthly, interval: 3, monthDay: 31),
            RecurrenceSpec(frequency: .monthly, interval: 1, nthWeekday: NthWeekday(nth: -1, weekday: 6)),
            RecurrenceSpec(frequency: .yearly, interval: 4, monthDay: 15, months: [6])
        ]
        for spec in specs {
            XCTAssertFalse(RecurrenceEKMapper.isLocalOnly(spec, isLunar: false), "\(spec) 不应判为仅本地")
            XCTAssertNotNil(RecurrenceEKMapper.rule(for: spec, anchor: anchor, isLunar: false), "\(spec) 应能写 EK 规则")
        }
    }

    func testHourlyIsLocalOnly() {
        let spec = RecurrenceSpec(frequency: .hourly, interval: 1)
        XCTAssertTrue(RecurrenceEKMapper.isLocalOnly(spec, isLunar: false))
        XCTAssertNil(RecurrenceEKMapper.rule(for: spec, anchor: anchor, isLunar: false))
    }

    func testLunarIsLocalOnly() {
        // 公历可表达的规则叠加农历后仍属于仅本地
        let spec = RecurrenceSpec(frequency: .daily, interval: 1)
        XCTAssertTrue(RecurrenceEKMapper.isLocalOnly(spec, isLunar: true))
        XCTAssertNil(RecurrenceEKMapper.rule(for: spec, anchor: anchor, isLunar: true))
    }

    // MARK: - 每小时仅本地（回归：永不写系统、永不进镜像计划）

    func testHourlyNeverEntersLunarMirrorPlan() {
        let hourly = RecurrenceSpec(frequency: .hourly, interval: 1)
        let start = anchor
        let end = anchor.addingTimeInterval(60 * 60 * 24 * 30)
        XCTAssertTrue(
            LunarMirrorPolicy.occurrences(spec: hourly, origin: anchor, after: start, through: end).isEmpty,
            "每小时不得进入镜像枚举"
        )
        let plan = LunarMirrorPolicy.reconcile(
            baseID: "hourly-base",
            currentDate: anchor, origin: anchor, spec: hourly, isLunar: false,
            validStart: nil, validEnd: nil, completedDates: [],
            now: anchor, existing: []
        )
        XCTAssertTrue(plan.createDates.isEmpty, "每小时不得产生镜像计划")
    }

    func testInvalidFrequencyRawValueWouldBecomeDailySoHourlyMustBeBlocked() {
        // 取证：Swift 可构造越界频度；EventKit 构造规则时静默钳成 0（daily）
        let invalid = EKRecurrenceFrequency(rawValue: 4)
        XCTAssertNotNil(invalid, "Swift 侧允许构造越界频度，必须在进入 EventKit 前拦截")
        let clamped = EKRecurrenceRule(recurrenceWith: invalid!, interval: 1, end: nil)
        XCTAssertEqual(clamped.frequency.rawValue, 0, "越界频度 4 会被 EventKit 钳成每天")

        // 应用侧唯一相关入口是 hourly：必须在映射层返回 nil，不能依赖 EK 钳制写「每天」
        XCTAssertNil(
            RecurrenceEKMapper.rule(
                for: RecurrenceSpec(frequency: .hourly, interval: 1),
                anchor: anchor,
                isLunar: false
            ),
            "hourly 若返回规则，等价于手工传 4 被写成每天"
        )
    }

    /// B 回归：删除 `.hourly → .daily` 分支后，任意 hourly 组合都不得产出规则
    func testHourlyNeverProducesAnyEKRule() {
        let specs: [RecurrenceSpec] = [
            RecurrenceSpec(frequency: .hourly, interval: 1),
            RecurrenceSpec(frequency: .hourly, interval: 6, end: .after(3)),
            RecurrenceSpec(frequency: .hourly, interval: 24)
        ]
        for spec in specs {
            XCTAssertNil(
                RecurrenceEKMapper.rule(for: spec, anchor: anchor, isLunar: false),
                "hourly 任何组合都不得写入系统规则：\(spec)"
            )
        }
    }
}
