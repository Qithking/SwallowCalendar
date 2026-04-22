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
    
    // MARK: - 农历日期解析测试
    
    func testParseLunarDate() {
        // 测试农历日期解析
        let result = NLPTaskParser.parse("农历7月8日老妈生日")
        
        // 验证标题清理正确
        XCTAssertEqual(result.title, "老妈生日")
        
        // 验证标记为农历
        XCTAssertTrue(result.isLunar)
        
        // 验证日期不为空
        XCTAssertNotNil(result.date)
        
        // 验证日期在未来（今年或明年）
        let now = Date()
        XCTAssertGreaterThan(result.date, now, "农历日期应该在未来")
        
        // 验证日期在3年内
        let threeYearsLater = Calendar.current.date(byAdding: .year, value: 3, to: now)!
        XCTAssertLessThan(result.date, threeYearsLater, "农历日期应该在3年内")
        
        // 验证转换回农历后月份和日期匹配
        let chineseCalendar = Calendar(identifier: .chinese)
        let lunarComponents = chineseCalendar.dateComponents([.month, .day], from: result.date)
        XCTAssertEqual(lunarComponents.month, 7, "农历月份应该为7")
        XCTAssertEqual(lunarComponents.day, 8, "农历日期应该为8")
    }
    
    func testParseRecurringLunarDate() {
        // 测试循环农历日期解析
        let result = NLPTaskParser.parse("每年农历7月8日老妈生日")
        
        // 验证标题清理正确
        XCTAssertEqual(result.title, "老妈生日")
        
        // 验证标记为农历和循环农历
        XCTAssertTrue(result.isLunar)
        XCTAssertTrue(result.isRecurringLunar)
        
        // 验证周期为每年
        XCTAssertEqual(result.recurrence, .yearly)
        
        // 验证日期不为空
        XCTAssertNotNil(result.date)
        
        // 验证日期在未来
        let now = Date()
        XCTAssertGreaterThan(result.date, now, "农历日期应该在未来")
        
        // 验证日期在3年内
        let threeYearsLater = Calendar.current.date(byAdding: .year, value: 3, to: now)!
        XCTAssertLessThan(result.date, threeYearsLater, "农历日期应该在3年内")
        
        // 验证转换回农历后月份和日期匹配
        let chineseCalendar = Calendar(identifier: .chinese)
        let lunarComponents = chineseCalendar.dateComponents([.month, .day], from: result.date)
        XCTAssertEqual(lunarComponents.month, 7, "农历月份应该为7")
        XCTAssertEqual(lunarComponents.day, 8, "农历日期应该为8")
    }
    
    func testParseLunarDateWithOtherAttributes() {
        // 测试农历日期与其他属性组合
        let result = NLPTaskParser.parse("农历正月初一春节 红色 重要 每年循环")
        
        // 验证各个属性
        XCTAssertEqual(result.title, "春节")
        XCTAssertEqual(result.color, .red)
        XCTAssertEqual(result.priority, .high)
        XCTAssertEqual(result.recurrence, .yearly)
        XCTAssertTrue(result.isLunar)
        
        // 验证日期
        XCTAssertNotNil(result.date)
        let now = Date()
        XCTAssertGreaterThan(result.date, now)
        
        // 验证农历日期
        let chineseCalendar = Calendar(identifier: .chinese)
        let lunarComponents = chineseCalendar.dateComponents([.month, .day], from: result.date)
        XCTAssertEqual(lunarComponents.month, 1, "农历月份应该为1（正月）")
        XCTAssertEqual(lunarComponents.day, 1, "农历日期应该为1（初一）")
    }
    
    func testParseYinliDate() {
        // 测试"阴历"格式（与"农历"等价）
        let result = NLPTaskParser.parse("阴历8月15中秋节")
        
        XCTAssertEqual(result.title, "中秋节")
        XCTAssertTrue(result.isLunar)
        XCTAssertNotNil(result.date)
        
        // 验证农历日期
        let chineseCalendar = Calendar(identifier: .chinese)
        let lunarComponents = chineseCalendar.dateComponents([.month, .day], from: result.date)
        XCTAssertEqual(lunarComponents.month, 8)
        XCTAssertEqual(lunarComponents.day, 15)
    }
    
    func testLunarDateAccuracy() {
        // 测试多个农历日期的准确性
        let testCases: [(input: String, expectedMonth: Int, expectedDay: Int, expectedTitle: String)] = [
            ("农历1月1日元旦", 1, 1, "元旦"),
            ("农历5月5日端午节", 5, 5, "端午节"),
            ("农历7月7日七夕", 7, 7, "七夕"),
            ("农历8月15日中秋节", 8, 15, "中秋节"),
            ("农历9月9日重阳节", 9, 9, "重阳节"),
            ("农历12月30日除夕", 12, 30, "除夕"),
        ]
        
        let chineseCalendar = Calendar(identifier: .chinese)
        
        for testCase in testCases {
            let result = NLPTaskParser.parse(testCase.input)
            
            XCTAssertEqual(result.title, testCase.expectedTitle, "Failed for: \(testCase.input)")
            XCTAssertTrue(result.isLunar, "Failed for: \(testCase.input)")
            XCTAssertNotNil(result.date, "Failed for: \(testCase.input)")
            
            let lunarComponents = chineseCalendar.dateComponents([.month, .day], from: result.date)
            XCTAssertEqual(lunarComponents.month, testCase.expectedMonth, "Month mismatch for: \(testCase.input)")
            XCTAssertEqual(lunarComponents.day, testCase.expectedDay, "Day mismatch for: \(testCase.input)")
        }
    }
    
    func testLunarDateRegression() {
        // 回归测试：确保农历解析不影响其他日期解析
        // 测试普通公历日期解析仍然正常
        let result1 = NLPTaskParser.parse("明天下午3点开会")
        XCTAssertEqual(result1.title, "开会")
        XCTAssertFalse(result1.isLunar)
        
        let result2 = NLPTaskParser.parse("后天上午9点体检")
        XCTAssertEqual(result2.title, "体检")
        XCTAssertFalse(result2.isLunar)
        
        // 测试绝对日期解析仍然正常
        let result3 = NLPTaskParser.parse("12月25日圣诞节")
        XCTAssertEqual(result3.title, "圣诞节")
        XCTAssertFalse(result3.isLunar)
        
        // 测试时间格式解析仍然正常
        let result4 = NLPTaskParser.parse("20:15开会")
        XCTAssertEqual(result4.title, "开会")
        XCTAssertFalse(result4.isLunar)
        
        let result5 = NLPTaskParser.parse("14点30会议")
        XCTAssertEqual(result5.title, "会议")
        XCTAssertFalse(result5.isLunar)
    }
    
    // MARK: - 周期任务测试
    
    func testParseRecurringTaskWithLunar() {
        // 测试农历周期任务解析
        let result = NLPTaskParser.parse("每年农历7月8日老妈生日")
        
        XCTAssertEqual(result.title, "老妈生日")
        XCTAssertTrue(result.isLunar)
        XCTAssertTrue(result.isRecurringLunar)
        XCTAssertEqual(result.recurrence, .yearly)
        XCTAssertNotNil(result.date)
    }
    
    func testParseRecurringTaskWithGregorian() {
        // 测试公历周期任务解析
        let result = NLPTaskParser.parse("每周一上午9点晨会")
        
        XCTAssertEqual(result.title, "晨会")
        XCTAssertFalse(result.isLunar)
        XCTAssertEqual(result.recurrence, .weekly)
        XCTAssertNotNil(result.date)
    }
}