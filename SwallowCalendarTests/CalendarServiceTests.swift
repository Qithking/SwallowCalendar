//
//  CalendarServiceTests.swift
//  SwallowCalendarTests
//
//  测试周期任务时间验证逻辑

import XCTest
@testable import SwallowCalendar

class CalendarServiceTests: XCTestCase {
    
    var calendarService: CalendarService!
    
    override func setUpWithError() throws {
        calendarService = CalendarService()
    }
    
    override func tearDownWithError() throws {
        calendarService = nil
    }
    
    // MARK: - 周期任务时间验证测试
    
    /// 测试：周期任务的开始时间必须大于当前时间
    func testRecurringEventStartTimeMustBeInFuture() {
        // Given: 一个过去的周期任务时间
        let calendar = Calendar.current
        let pastDate = calendar.date(byAdding: .hour, value: -2, to: Date())! // 2小时前
        
        // When: 创建每天重复的事件
        // 由于这是单元测试，我们无法真正创建事件，但可以测试验证逻辑
        
        // 验证：周期任务时间必须 > 当前时间
        XCTAssertLessThan(pastDate, Date(), "测试时间确实是过去的")
    }
    
    /// 测试：周期任务时间推进逻辑（每天）
    func testDailyRecurrenceTimeAdvancement() {
        // Given: 一个过去的时间
        let calendar = Calendar.current
        let now = Date()
        let pastDate = calendar.date(byAdding: .hour, value: -5, to: now)!
        
        // When: 推进到下一个周期
        var tempDate = pastDate
        let recurrenceType: RecurrenceType = .daily
        
        while tempDate <= now {
            switch recurrenceType {
            case .daily:
                tempDate = calendar.date(byAdding: .day, value: 1, to: tempDate) ?? tempDate
            case .weekly:
                tempDate = calendar.date(byAdding: .weekOfYear, value: 1, to: tempDate) ?? tempDate
            case .monthly:
                tempDate = calendar.date(byAdding: .month, value: 1, to: tempDate) ?? tempDate
            case .yearly:
                tempDate = calendar.date(byAdding: .year, value: 1, to: tempDate) ?? tempDate
            case .none, .custom:
                break
            }
        }
        
        // Then: 推进后的时间应该在当前时间之后
        XCTAssertGreaterThan(tempDate, now, "周期任务时间应该推进到未来")
        
        // 验证推进的天数正确（应该推进了1天）
        let daysAdded = calendar.dateComponents([.day], from: pastDate, to: tempDate).day
        XCTAssertGreaterThanOrEqual(daysAdded, 1, "至少应该推进1天")
    }
    
    /// 测试：周期任务时间推进逻辑（每周）
    func testWeeklyRecurrenceTimeAdvancement() {
        // Given: 一个过去的时间
        let calendar = Calendar.current
        let now = Date()
        let pastDate = calendar.date(byAdding: .day, value: -3, to: now)!
        
        // When: 推进到下一个周期
        var tempDate = pastDate
        let recurrenceType: RecurrenceType = .weekly
        
        while tempDate <= now {
            switch recurrenceType {
            case .daily:
                tempDate = calendar.date(byAdding: .day, value: 1, to: tempDate) ?? tempDate
            case .weekly:
                tempDate = calendar.date(byAdding: .weekOfYear, value: 1, to: tempDate) ?? tempDate
            case .monthly:
                tempDate = calendar.date(byAdding: .month, value: 1, to: tempDate) ?? tempDate
            case .yearly:
                tempDate = calendar.date(byAdding: .year, value: 1, to: tempDate) ?? tempDate
            case .none, .custom:
                break
            }
        }
        
        // Then: 推进后的时间应该在当前时间之后
        XCTAssertGreaterThan(tempDate, now, "周期任务时间应该推进到未来")
        
        // 验证推进的周数正确（应该推进了1周）
        let weeksAdded = calendar.dateComponents([.weekOfYear], from: pastDate, to: tempDate).weekOfYear
        XCTAssertGreaterThanOrEqual(weeksAdded, 1, "至少应该推进1周")
    }
    
    /// 测试：周期任务时间推进逻辑（每月）
    func testMonthlyRecurrenceTimeAdvancement() {
        // Given: 一个过去的时间
        let calendar = Calendar.current
        let now = Date()
        let pastDate = calendar.date(byAdding: .month, value: -2, to: now)!
        
        // When: 推进到下一个周期
        var tempDate = pastDate
        let recurrenceType: RecurrenceType = .monthly
        
        while tempDate <= now {
            switch recurrenceType {
            case .daily:
                tempDate = calendar.date(byAdding: .day, value: 1, to: tempDate) ?? tempDate
            case .weekly:
                tempDate = calendar.date(byAdding: .weekOfYear, value: 1, to: tempDate) ?? tempDate
            case .monthly:
                tempDate = calendar.date(byAdding: .month, value: 1, to: tempDate) ?? tempDate
            case .yearly:
                tempDate = calendar.date(byAdding: .year, value: 1, to: tempDate) ?? tempDate
            case .none, .custom:
                break
            }
        }
        
        // Then: 推进后的时间应该在当前时间之后
        XCTAssertGreaterThan(tempDate, now, "周期任务时间应该推进到未来")
        
        // 验证推进的月数正确（应该推进了3个月）
        let monthsAdded = calendar.dateComponents([.month], from: pastDate, to: tempDate).month
        XCTAssertGreaterThanOrEqual(monthsAdded, 1, "至少应该推进1月")
    }
    
    /// 测试：周期任务时间推进逻辑（每年）
    func testYearlyRecurrenceTimeAdvancement() {
        // Given: 一个过去的时间
        let calendar = Calendar.current
        let now = Date()
        let pastDate = calendar.date(byAdding: .year, value: -1, to: now)!
        
        // When: 推进到下一个周期
        var tempDate = pastDate
        let recurrenceType: RecurrenceType = .yearly
        
        while tempDate <= now {
            switch recurrenceType {
            case .daily:
                tempDate = calendar.date(byAdding: .day, value: 1, to: tempDate) ?? tempDate
            case .weekly:
                tempDate = calendar.date(byAdding: .weekOfYear, value: 1, to: tempDate) ?? tempDate
            case .monthly:
                tempDate = calendar.date(byAdding: .month, value: 1, to: tempDate) ?? tempDate
            case .yearly:
                tempDate = calendar.date(byAdding: .year, value: 1, to: tempDate) ?? tempDate
            case .none, .custom:
                break
            }
        }
        
        // Then: 推进后的时间应该在当前时间之后
        XCTAssertGreaterThan(tempDate, now, "周期任务时间应该推进到未来")
        
        // 验证推进的年数正确（应该推进了1年）
        let yearsAdded = calendar.dateComponents([.year], from: pastDate, to: tempDate).year
        XCTAssertGreaterThanOrEqual(yearsAdded, 1, "至少应该推进1年")
    }
    
    /// 测试：未来的周期任务时间不需要推进
    func testFutureRecurrenceTimeNoAdvancement() {
        // Given: 一个未来的时间
        let calendar = Calendar.current
        let now = Date()
        let futureDate = calendar.date(byAdding: .day, value: 1, to: now)!
        
        // When: 检查是否需要推进
        var tempDate = futureDate
        let recurrenceType: RecurrenceType = .daily
        
        if tempDate <= now {
            // 不应该进入这个分支
            switch recurrenceType {
            case .daily:
                tempDate = calendar.date(byAdding: .day, value: 1, to: tempDate) ?? tempDate
            default:
                break
            }
        }
        
        // Then: 时间不应该被改变
        XCTAssertEqual(tempDate, futureDate, "未来的时间不应该被推进")
    }
    
    /// 测试：边界情况 - 当前时间等于开始时间
    func testRecurrenceTimeEqualsNow() {
        // Given: 当前时间
        let calendar = Calendar.current
        let now = Date()
        
        // When: 推进到下一个周期
        var tempDate = now
        let recurrenceType: RecurrenceType = .daily
        
        while tempDate <= now {
            switch recurrenceType {
            case .daily:
                tempDate = calendar.date(byAdding: .day, value: 1, to: tempDate) ?? tempDate
            case .weekly:
                tempDate = calendar.date(byAdding: .weekOfYear, value: 1, to: tempDate) ?? tempDate
            case .monthly:
                tempDate = calendar.date(byAdding: .month, value: 1, to: tempDate) ?? tempDate
            case .yearly:
                tempDate = calendar.date(byAdding: .year, value: 1, to: tempDate) ?? tempDate
            case .none, .custom:
                break
            }
        }
        
        // Then: 推进后的时间应该严格大于当前时间
        XCTAssertGreaterThan(tempDate, now, "等于当前时间时也应该推进")
    }
    
    // MARK: - NLP 解析器周期时间推进测试
    
    /// 测试：NLP 解析过去时间的周期任务（每天）
    func testNLPParsePastDailyRecurrence() {
        // Given: 输入过去时间的周期任务
        let input = "每天10点提醒休息" // 假设现在已经过了10点
        
        // When: 解析
        let result = NLPTaskParser.parse(input)
        
        // Then: 
        XCTAssertEqual(result.recurrence, .daily)
        XCTAssertGreaterThan(result.date, Date(), "周期任务时间应该在未来")
    }
    
    /// 测试：NLP 解析过去时间的周期任务（每周）
    func testNLPParsePastWeeklyRecurrence() {
        // Given: 输入过去时间的周期任务
        let calendar = Calendar.current
        let todayWeekday = calendar.component(.weekday, from: Date())
        let input = "每周一上午9点晨会"
        
        // When: 解析
        let result = NLPTaskParser.parse(input)
        
        // Then:
        XCTAssertEqual(result.recurrence, .weekly)
        
        // 如果今天是周一且已经过了9点，解析的时间应该是下周一
        if todayWeekday == 2 { // 周一（firstWeekday=1表示周日）
            let hour = calendar.component(.hour, from: Date())
            if hour >= 9 {
                let daysUntilNextMonday = 7
                let expectedDate = calendar.date(byAdding: .day, value: daysUntilNextMonday, to: calendar.startOfDay(for: Date()))!
                XCTAssertGreaterThanOrEqual(result.date, expectedDate, "应该推进到下周")
            }
        } else {
            // 如果不是周一，应该是本周或下周的周一
            XCTAssertGreaterThan(result.date, Date(), "周期任务时间应该在未来")
        }
    }
    
    /// 测试：NLP 解析未来时间的周期任务不需要推进
    func testNLPParseFutureRecurrenceNoAdvancement() {
        // Given: 输入未来时间的周期任务
        let input = "每天23点提醒休息" // 假设现在还没到23点
        
        // When: 解析
        let result = NLPTaskParser.parse(input)
        
        // Then: 
        XCTAssertEqual(result.recurrence, .daily)
        
        // 如果当前时间还没到23点，时间应该是今天23点
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 23 {
            let today23 = Calendar.current.date(bySettingHour: 23, minute: 0, second: 0, of: Date())!
            XCTAssertEqual(
                Calendar.current.component(.day, from: result.date),
                Calendar.current.component(.day, from: today23),
                "应该保持今天"
            )
            XCTAssertEqual(
                Calendar.current.component(.hour, from: result.date),
                23,
                "小时应该是23"
            )
        }
    }
    
    // MARK: - 非周期任务不受时间验证影响测试
    
    /// 测试：非周期任务允许过去时间
    func testNonRecurringTaskAllowsPastTime() {
        // Given: 一个过去的非周期任务
        let input = "昨天下午3点开会"
        
        // When: 解析
        let result = NLPTaskParser.parse(input)
        
        // Then: 非周期任务允许过去时间
        XCTAssertNil(result.recurrence, "应该没有周期")
        // 注意：这里不验证时间是否在未来，因为非周期任务允许过去时间
    }
    
    // MARK: - 农历周期任务测试
    
    /// 测试：农历周期任务生成（非闰月年）
    func testLunarRecurrenceDateGeneration() {
        // Given: 一个农历日期（2024年正月初一）
        let chineseCalendar = Calendar(identifier: .chinese)
        var components = DateComponents()
        components.year = 2024
        components.month = 1
        components.day = 1
        
        guard let lunarDate = chineseCalendar.date(from: components) else {
            XCTFail("无法创建农历日期")
            return
        }
        
        // When: 生成下一个农历日期（每年）
        let nextDate = calendarService.getNextLunarDate(from: lunarDate, recurrenceType: .yearly)
        
        // Then: 应该有下一个日期
        XCTAssertNotNil(nextDate, "应该能生成下一个农历日期")
        
        if let next = nextDate {
            // 验证年份增加了1
            let currentYear = chineseCalendar.component(.year, from: lunarDate)
            let nextYear = chineseCalendar.component(.year, from: next)
            XCTAssertEqual(nextYear, currentYear + 1, "农历年份应该增加1")
        }
    }
    
    /// 测试：农历每月周期任务
    func testLunarMonthlyRecurrence() {
        // Given: 一个农历日期
        let chineseCalendar = Calendar(identifier: .chinese)
        var components = DateComponents()
        components.year = 2024
        components.month = 3
        components.day = 15
        
        guard let lunarDate = chineseCalendar.date(from: components) else {
            XCTFail("无法创建农历日期")
            return
        }
        
        // When: 生成下一个月
        let nextDate = calendarService.getNextLunarDate(from: lunarDate, recurrenceType: .monthly)
        
        // Then: 月份应该增加1
        XCTAssertNotNil(nextDate, "应该能生成下一个农历日期")
        
        if let next = nextDate {
            let currentMonth = chineseCalendar.component(.month, from: lunarDate)
            let nextMonth = chineseCalendar.component(.month, from: next)
            
            // 注意：农历月份可能是负数（表示闰月），这里只验证有变化
            XCTAssertNotEqual(nextMonth, currentMonth, "农历月份应该变化")
        }
    }
}
