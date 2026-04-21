//
//  NLPTaskParserTests.swift
//  SwallowCalendarTests
//

import XCTest
@testable import SwallowCalendar

class NLPTaskParserTests: XCTestCase {

    func testParseChineseDateWithTime() {
        // 测试带时间的日期解析
        let result1 = NLPTaskParser.parse("明天下午3点开会")
        XCTAssertNotNil(result1.date)
        XCTAssertEqual(result1.title, "开会")
        
        let result2 = NLPTaskParser.parse("今天上午9点体检")
        XCTAssertNotNil(result2.date)
        XCTAssertEqual(result2.title, "体检")
        
        let result3 = NLPTaskParser.parse("后天晚上8点聚餐")
        XCTAssertNotNil(result3.date)
        XCTAssertEqual(result3.title, "聚餐")
    }
    
    func testParseReminderTime() {
        // 测试提醒时间解析
        let result1 = NLPTaskParser.parse("明天下午3点开会 提前30分钟")
        XCTAssertEqual(result1.reminderMinutes, 30)
        XCTAssertEqual(result1.title, "开会")
        
        let result2 = NLPTaskParser.parse("今天上午9点体检 1小时前提醒")
        XCTAssertEqual(result2.reminderMinutes, 60)
        XCTAssertEqual(result2.title, "体检")
        
        let result3 = NLPTaskParser.parse("后天晚上8点聚餐 2天前提醒")
        XCTAssertEqual(result3.reminderMinutes, 2880) // 2天 = 2880分钟
        XCTAssertEqual(result3.title, "聚餐")
    }
    
    func testParseColorsAndPriorities() {
        // 测试颜色和优先级解析
        let result1 = NLPTaskParser.parse("明天下午3点开会 红色 重要")
        XCTAssertEqual(result1.color, .red)
        XCTAssertEqual(result1.priority, .high)
        XCTAssertEqual(result1.title, "开会")
        
        let result2 = NLPTaskParser.parse("后天上午10点体检 蓝色 普通")
        XCTAssertEqual(result2.color, .blue)
        XCTAssertEqual(result2.priority, .medium)
        XCTAssertEqual(result2.title, "体检")
    }
    
    func testParseRecurrence() {
        // 测试周期解析
        let result1 = NLPTaskParser.parse("每天下午3点开会 循环")
        XCTAssertEqual(result1.recurrence, .daily)
        XCTAssertEqual(result1.title, "开会")
        
        let result2 = NLPTaskParser.parse("明天上午9点晨会 每周重复")
        XCTAssertEqual(result2.recurrence, .weekly)
        XCTAssertEqual(result2.title, "晨会")
    }
    
    func testComplexInput() {
        // 测试复杂输入
        let result = NLPTaskParser.parse("明天下午3点开会 红色 重要 每天循环 提前30分钟")
        XCTAssertEqual(result.title, "开会")
        XCTAssertEqual(result.color, .red)
        XCTAssertEqual(result.priority, .high)
        XCTAssertEqual(result.recurrence, .daily)
        XCTAssertEqual(result.reminderMinutes, 30)
        
        // 检查日期是否为明天的下午3点
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))!
        let expectedDate = calendar.date(bySettingHour: 15, minute: 0, second: 0, of: tomorrow)!
        XCTAssertEqual(calendar.component(.year, from: result.date), calendar.component(.year, from: expectedDate))
        XCTAssertEqual(calendar.component(.month, from: result.date), calendar.component(.month, from: expectedDate))
        XCTAssertEqual(calendar.component(.day, from: result.date), calendar.component(.day, from: expectedDate))
        XCTAssertEqual(calendar.component(.hour, from: result.date), calendar.component(.hour, from: expectedDate))
        XCTAssertEqual(calendar.component(.minute, from: result.date), calendar.component(.minute, from: expectedDate))
    }
    
    func testFlexibleReminderParsing() {
        // 测试灵活的提醒时间解析
        let inputs = [
            ("开会 提前15分钟", 15),
            ("会议 45分钟前提醒", 45),
            ("聚餐 提前2小时", 120),
            ("活动 3小时前提醒", 180),
            ("生日 提前7天", 10080)  // 7 * 24 * 60
        ]
        
        for (input, expectedMinutes) in inputs {
            let result = NLPTaskParser.parse(input)
            XCTAssertEqual(result.reminderMinutes, expectedMinutes, "Failed for input: \(input)")
        }
    }
    
    func testParseColonTimeFormat() {
        // 测试 HH:MM 格式的时间解析
        let result1 = NLPTaskParser.parse("20:15开会")
        XCTAssertNotNil(result1.date)
        XCTAssertEqual(result1.title, "开会")
        let calendar = Calendar.current
        XCTAssertEqual(calendar.component(.hour, from: result1.date), 20)
        XCTAssertEqual(calendar.component(.minute, from: result1.date), 15)
        
        let result2 = NLPTaskParser.parse("明天09:30体检")
        XCTAssertNotNil(result2.date)
        XCTAssertEqual(result2.title, "体检")
        XCTAssertEqual(calendar.component(.hour, from: result2.date), 9)
        XCTAssertEqual(calendar.component(.minute, from: result2.date), 30)
    }
    
    func testParseHourMinuteFormat() {
        // 测试 X点X分 格式（不带上午/下午）
        let result1 = NLPTaskParser.parse("20点15开会")
        XCTAssertNotNil(result1.date)
        XCTAssertEqual(result1.title, "开会")
        let calendar = Calendar.current
        XCTAssertEqual(calendar.component(.hour, from: result1.date), 20)
        XCTAssertEqual(calendar.component(.minute, from: result1.date), 15)
        
        let result2 = NLPTaskParser.parse("9点30体检")
        XCTAssertNotNil(result2.date)
        XCTAssertEqual(result2.title, "体检")
        XCTAssertEqual(calendar.component(.hour, from: result2.date), 9)
        XCTAssertEqual(calendar.component(.minute, from: result2.date), 30)
        
        let result3 = NLPTaskParser.parse("14点45会议")
        XCTAssertNotNil(result3.date)
        XCTAssertEqual(result3.title, "会议")
        XCTAssertEqual(calendar.component(.hour, from: result3.date), 14)
        XCTAssertEqual(calendar.component(.minute, from: result3.date), 45)
    }
}