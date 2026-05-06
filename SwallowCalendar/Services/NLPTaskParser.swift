//
//  NLPTaskParser.swift
//  SwallowCalendar
//

import Foundation

/// 自然语言任务解析器
struct NLPTaskParser {
    /// 解析自然语言输入，返回任务详情
    static func parse(_ input: String) -> ParsedTask {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return ParsedTask(title: "", date: Date())
        }

        // 解析日期（包括农历）
        let dateResult = parseChineseDate(trimmed)
        let title = cleanTitle(trimmed)

        var result = ParsedTask(title: title, date: dateResult.date)

        // 标记是否为农历
        if dateResult.isLunar {
            result.isLunar = true
        }

        // 提取颜色
        if let color = parseColor(from: trimmed) {
            result.color = color
        }

        // 提取优先级
        if let priority = parsePriority(from: trimmed) {
            result.priority = priority
        }

        // 提取周期
        if let recurrence = parseRecurrence(from: trimmed) {
            result.recurrence = recurrence
        }

        // 对于周期任务，如果时间已经过去，推进到下一个周期
        if let recurrence = result.recurrence, recurrence != .none && result.date < Date() {
            result.date = advanceToNextPeriod(date: result.date, recurrence: recurrence)
        }

        // 标记是否为循环农历
        if result.recurrence == .yearly && (trimmed.contains("农历") || trimmed.contains("阴历")) {
            result.isRecurringLunar = true
        }

        // 提取农历标记（如果没有解析到农历日期，但包含农历关键词）
        if !result.isLunar && (trimmed.contains("农历") || trimmed.contains("阴历")) {
            result.isLunar = true
        }

        // 提取提醒时间
        if let reminderMinutes = parseReminder(from: trimmed) {
            result.reminderMinutes = reminderMinutes
        }

        return result
    }

    /// 解析中文日期（包括农历）
    private static func parseChineseDate(_ input: String) -> (date: Date, matched: String, isLunar: Bool) {
        let calendar = Calendar.current
        let now = Date()
        
        // 首先尝试解析农历日期
        if let lunarResult = parseLunarDate(input, now: now) {
            return lunarResult
        }
        
        // 首先尝试解析时间部分（如"下午3点"、"20:15"、"20点15分"）
        var baseDate = calendar.startOfDay(for: now)  // 默认为今天的开始
        var matchedText = ""
        
        // 匹配 HH:MM 格式（如 20:15, 09:30）
        if let timeMatch = input.range(of: "(\\d{1,2}):(\\d{2})", options: .regularExpression) {
            let timeStr = String(input[timeMatch])
            let components = timeStr.split(separator: ":")
            if components.count == 2,
               let hour = Int(components[0]),
               let minute = Int(components[1]),
               hour >= 0, hour <= 23, minute >= 0, minute <= 59 {
                var dateComponents = calendar.dateComponents([.year, .month, .day], from: baseDate)
                dateComponents.hour = hour
                dateComponents.minute = minute
                dateComponents.second = 0
                
                if let date = calendar.date(from: dateComponents) {
                    baseDate = date
                    matchedText = timeStr
                }
            }
        }
        // 匹配 X点X分 格式（不带上午/下午前缀，如 20点15, 9点30分）
        else if let timeMatch = input.range(of: "(\\d{1,2})点(\\d{1,2})(分)?", options: .regularExpression) {
            let timeStr = String(input[timeMatch])
            
            // 使用正则提取数字
            let numberPattern = "(\\d+)"
            var numbers: [Int] = []
            var searchRange = timeStr.startIndex..<timeStr.endIndex
            
            while let match = timeStr.range(of: numberPattern, options: .regularExpression, range: searchRange) {
                if let num = Int(timeStr[match]) {
                    numbers.append(num)
                }
                searchRange = match.upperBound..<timeStr.endIndex
            }
            
            if numbers.count >= 2,
               let hour = numbers.first,
               let minute = numbers.last,
               hour >= 0, hour <= 23, minute >= 0, minute <= 59 {
                var dateComponents = calendar.dateComponents([.year, .month, .day], from: baseDate)
                dateComponents.hour = hour
                dateComponents.minute = minute
                dateComponents.second = 0
                
                if let date = calendar.date(from: dateComponents) {
                    baseDate = date
                    matchedText = timeStr
                }
            }
        }
        // 匹配带时间段的时间格式，如"下午3点"、"上午9点"、"晚上8点"
        else if let timeMatch = input.range(of: "(上午|下午|晚上|凌晨)?(\\d{1,2})点(\\d{1,2}分)?", options: .regularExpression) {
            let timeStr = String(input[timeMatch])
            
            // 提取小时和分钟
            let timePattern = "(\\d{1,2})点(\\d{1,2}分)?"
            if let timeRange = timeStr.range(of: timePattern, options: .regularExpression) {
                let extractedTime = String(timeStr[timeRange])
                let numbers = extractedTime.filter { $0.isNumber }
                let parts = numbers.split(separator: " ")
                
                if let hour = Int(parts[0]) {
                    var finalHour = hour
                    let isAfternoon = timeStr.contains("下午") || timeStr.contains("晚上")
                    
                    if hour >= 12 {
                        // 如果小时 >= 12，说明已经是24小时制，直接使用
                        finalHour = hour
                    } else if isAfternoon {
                        // 小时 < 12 且有下午/晚上标识，加12小时
                        finalHour = hour + 12
                    }
                    // 其他情况（上午/凌晨或无标识）直接使用原始小时数
                    
                    let minute = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
                    
                    var components = calendar.dateComponents([.year, .month, .day], from: baseDate)
                    components.hour = finalHour
                    components.minute = minute
                    components.second = 0
                    
                    if let date = calendar.date(from: components) {
                        baseDate = date
                        matchedText = timeStr
                    }
                }
            }
        }

        // 优先匹配精确词
        if input.contains("大后天") {
            let date = calendar.date(byAdding: .day, value: 3, to: calendar.startOfDay(for: now))
            if let d = date {
                // 如果已经有时间信息，则更新日期部分但保留时间
                var components = calendar.dateComponents([.hour, .minute, .second], from: baseDate)
                components.year = calendar.component(.year, from: d)
                components.month = calendar.component(.month, from: d)
                components.day = calendar.component(.day, from: d)
                if let finalDate = calendar.date(from: components) {
                    return (finalDate, "大后天" + matchedText, false)
                }
            }
            return (date ?? now, "大后天", false)
        }
        if input.contains("后天") {
            let date = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: now))
            if let d = date {
                var components = calendar.dateComponents([.hour, .minute, .second], from: baseDate)
                components.year = calendar.component(.year, from: d)
                components.month = calendar.component(.month, from: d)
                components.day = calendar.component(.day, from: d)
                if let finalDate = calendar.date(from: components) {
                    return (finalDate, "后天" + matchedText, false)
                }
            }
            return (date ?? now, "后天", false)
        }
        if input.contains("明天") {
            let date = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
            if let d = date {
                var components = calendar.dateComponents([.hour, .minute, .second], from: baseDate)
                components.year = calendar.component(.year, from: d)
                components.month = calendar.component(.month, from: d)
                components.day = calendar.component(.day, from: d)
                if let finalDate = calendar.date(from: components) {
                    return (finalDate, "明天" + matchedText, false)
                }
            }
            return (date ?? now, "明天", false)
        }
        if input.contains("今天") {
            if !matchedText.isEmpty {
                return (baseDate, "今天" + matchedText, false)
            }
            return (calendar.startOfDay(for: now), "今天", false)
        }

        // 匹配 X天后/小时/分钟后
        if let match = input.range(of: "(\\d+)天后", options: .regularExpression) {
            let matched = String(input[match])
            let numbers = matched.filter { $0.isNumber }
            if let days = Int(numbers) {
                let date = calendar.date(byAdding: .day, value: days, to: now)
                if let d = date {
                    var components = calendar.dateComponents([.hour, .minute, .second], from: baseDate)
                    components.year = calendar.component(.year, from: d)
                    components.month = calendar.component(.month, from: d)
                    components.day = calendar.component(.day, from: d)
                    if let finalDate = calendar.date(from: components) {
                        return (finalDate, matched + matchedText, false)
                    }
                }
                return (date ?? now, matched, false)
            }
        }
        if let match = input.range(of: "(\\d+)小时后", options: .regularExpression) {
            let matched = String(input[match])
            let numbers = matched.filter { $0.isNumber }
            if let hours = Int(numbers) {
                let date = calendar.date(byAdding: .hour, value: hours, to: now)
                return (date ?? now, matched, false)
            }
        }
        if let match = input.range(of: "(\\d+)分钟后", options: .regularExpression) {
            let matched = String(input[match])
            let numbers = matched.filter { $0.isNumber }
            if let minutes = Int(numbers) {
                let date = calendar.date(byAdding: .minute, value: minutes, to: now)
                return (date ?? now, matched, false)
            }
        }

        // 匹配 X月X日 格式
        if let match = input.range(of: "(\\d+)月(\\d+)[日号]", options: .regularExpression) {
            let matched = String(input[match])
            let numbers = matched.filter { $0.isNumber }
            let parts = numbers.split(separator: " ")
            if parts.count >= 2,
               let month = Int(parts[0]), let day = Int(parts[1]),
               month >= 1, month <= 12, day >= 1, day <= 31 {
                var components = calendar.dateComponents([.year], from: now)
                components.month = month
                components.day = day
                var date = calendar.date(from: components)
                if let d = date, d < calendar.startOfDay(for: now) {
                    components.year = (components.year ?? 2026) + 1
                    date = calendar.date(from: components)
                }
                
                // 如果已经有时间信息，合并日期和时间
                if let d = date {
                    var timeComponents = calendar.dateComponents([.hour, .minute, .second], from: baseDate)
                    timeComponents.year = calendar.component(.year, from: d)
                    timeComponents.month = calendar.component(.month, from: d)
                    timeComponents.day = calendar.component(.day, from: d)
                    if let finalDate = calendar.date(from: timeComponents) {
                        return (finalDate, matched + matchedText, false)
                    }
                }
                return (date ?? now, matched, false)
            }
        }

        // 匹配星期X 或 周X 格式（如"周五"、"星期三"）
        // 使用固定周日=1的Calendar，不受用户firstWeekday设置影响
        var gregorianForWeekday = Calendar(identifier: .gregorian)
        gregorianForWeekday.firstWeekday = 1  // 周日=1
        
        let weekdayKeywords: [(keyword: String, targetWeekday: Int)] = [
            ("周日", 1), ("星期日", 1),
            ("周一", 2), ("星期一", 2),
            ("周二", 3), ("星期二", 3),
            ("周三", 4), ("星期三", 4),
            ("周四", 5), ("星期四", 5),
            ("周五", 6), ("星期五", 6),
            ("周六", 7), ("星期六", 7)
        ]
        
        for item in weekdayKeywords {
            if input.contains(item.keyword) {
                // 找到最近的该星期几
                let currentWeekday = gregorianForWeekday.component(.weekday, from: now)
                var daysToAdd = item.targetWeekday - currentWeekday
                
                if daysToAdd < 0 {
                    // 目标星期几已经过去，加7天到下周
                    daysToAdd += 7
                } else if daysToAdd == 0 {
                    // 今天就是目标星期几，检查时间是否已过
                    if !matchedText.isEmpty {
                        let timeComponents = gregorianForWeekday.dateComponents([.hour, .minute], from: baseDate)
                        if let hour = timeComponents.hour, let minute = timeComponents.minute {
                            var timeDateComponents = gregorianForWeekday.dateComponents([.year, .month, .day], from: now)
                            timeDateComponents.hour = hour
                            timeDateComponents.minute = minute
                            if let timeDate = gregorianForWeekday.date(from: timeDateComponents),
                               timeDate < now {
                                // 时间已过，加7天到下周
                                daysToAdd += 7
                            }
                        }
                    }
                    // 如果没时间信息或时间还没到，daysToAdd 保持 0（今天）
                }
                
                let targetDate = gregorianForWeekday.date(byAdding: .day, value: daysToAdd, to: gregorianForWeekday.startOfDay(for: now))
                
                if let d = targetDate {
                    var timeComponents = gregorianForWeekday.dateComponents([.hour, .minute, .second], from: baseDate)
                    timeComponents.year = gregorianForWeekday.component(.year, from: d)
                    timeComponents.month = gregorianForWeekday.component(.month, from: d)
                    timeComponents.day = gregorianForWeekday.component(.day, from: d)
                    if let finalDate = gregorianForWeekday.date(from: timeComponents) {
                        return (finalDate, item.keyword + matchedText, false)
                    }
                }
                
                return (targetDate ?? now, item.keyword, false)
            }
        }

        // 如果没有找到特定日期但有时间，返回今天的时间
        if !matchedText.isEmpty {
            return (baseDate, matchedText, false)
        }

        // 默认今天
        return (now, "", false)
    }

    /// 解析农历日期
    /// 注意：农历Calendar使用佛历纪元，year不是公历年份
    /// 策略：从今年开始，逐天搜索，找到第一个匹配的农历日期
    private static func parseLunarDate(_ input: String, now: Date) -> (date: Date, matched: String, isLunar: Bool)? {
        // 匹配"农历X月X日"或"阴历X月X日"格式（支持数字前后有空格，如"农历 7 月 8 日"）
        let lunarPattern = "(?:农历|阴历)\\s*(\\d+)\\s*月\\s*(\\d+)\\s*[日号]?"
        guard let match = input.range(of: lunarPattern, options: .regularExpression) else {
            return nil
        }
        
        let matched = String(input[match])
        // 提取月份和日期数字
        let lunarRegex = try! NSRegularExpression(pattern: "(?:农历|阴历)\\s*(\\d+)\\s*月\\s*(\\d+)\\s*[日号]?")
        guard let fullMatch = lunarRegex.firstMatch(in: input, range: NSRange(match, in: input)),
              fullMatch.numberOfRanges >= 3,
              let monthRange = Range(fullMatch.range(at: 1), in: input),
              let dayRange = Range(fullMatch.range(at: 2), in: input),
              let lunarMonth = Int(String(input[monthRange])),
              let lunarDay = Int(String(input[dayRange])),
              lunarMonth >= 1, lunarMonth <= 12,
              lunarDay >= 1, lunarDay <= 30 else {
            return nil
        }
        
        let chineseCalendar = Calendar(identifier: .chinese)
        let gregorianCalendar = Calendar.current
        
        // 从今天开始，逐天搜索，最多搜索3年
        // 农历年约354天，3年约1062天，性能可接受
        var currentDate = gregorianCalendar.startOfDay(for: now)
        let maxDate = gregorianCalendar.date(byAdding: .year, value: 3, to: currentDate)!
        
        while currentDate < maxDate {
            // 将公历日期转为农历，检查是否匹配
            let lunarComponents = chineseCalendar.dateComponents([.month, .day], from: currentDate)
            
            if lunarComponents.month == lunarMonth && lunarComponents.day == lunarDay {
                // 找到匹配的农历日期
                return (currentDate, matched, true)
            }
            
            // 前进一天
            currentDate = gregorianCalendar.date(byAdding: .day, value: 1, to: currentDate)!
        }
        
        return nil
    }

    // MARK: - 颜色解析

    private static func parseColor(from input: String) -> EventColor? {
        if input.contains("红色") { return .red }
        if input.contains("橙色") { return .orange }
        if input.contains("黄色") { return .yellow }
        if input.contains("绿色") { return .green }
        if input.contains("蓝色") { return .blue }
        if input.contains("紫色") { return .purple }
        if input.contains("粉色") { return .pink }
        if input.contains("灰色") { return .gray }
        return nil
    }

    // MARK: - 优先级解析

    private static func parsePriority(from input: String) -> EventPriority? {
        if input.contains("重要") || input.contains("紧急") || input.contains("高优") || input.contains("最高") {
            return .high
        }
        if input.contains("中等") || input.contains("普通") || input.contains("一般") {
            return .medium
        }
        if input.contains("低优") || input.contains("次要") {
            return .low
        }
        return nil
    }

    // MARK: - 周期解析

    private static func parseRecurrence(from input: String) -> RecurrenceType? {
        // 优先匹配“每年农历”
        if input.contains("每年农历") || input.contains("每年阴历") {
            return .yearly
        }
        if input.contains("每天") || input.contains("日循环") || input.contains("循环") {
            return .daily
        }
        if input.contains("每周") || input.contains("周循环") {
            return .weekly
        }
        if input.contains("每月") || input.contains("月循环") {
            return .monthly
        }
        if input.contains("每年") || input.contains("年循环") {
            return .yearly
        }
        return nil
    }

    // MARK: - 提醒时间解析

    private static func parseReminder(from input: String) -> Int? {
        // 匹配 "提前X分钟" 或 "X分钟前"
        if let match = input.range(of: "提前(\\d+)分钟", options: .regularExpression) {
            let matched = String(input[match])
            let numbers = matched.filter { $0.isNumber }
            if let minutes = Int(numbers) {
                return minutes
            }
        }
        
        if let match = input.range(of: "(\\d+)分钟前", options: .regularExpression) {
            let matched = String(input[match])
            let numbers = matched.filter { $0.isNumber }
            if let minutes = Int(numbers) {
                return minutes
            }
        }
        
        // 匹配 "提前X小时" 或 "X小时前"
        if let match = input.range(of: "提前(\\d+)小时", options: .regularExpression) {
            let matched = String(input[match])
            let numbers = matched.filter { $0.isNumber }
            if let hours = Int(numbers) {
                return hours * 60
            }
        }
        
        if let match = input.range(of: "(\\d+)小时前", options: .regularExpression) {
            let matched = String(input[match])
            let numbers = matched.filter { $0.isNumber }
            if let hours = Int(numbers) {
                return hours * 60
            }
        }
        
        // 匹配 "提前X天" 或 "X天前"
        if let match = input.range(of: "提前(\\d+)天", options: .regularExpression) {
            let matched = String(input[match])
            let numbers = matched.filter { $0.isNumber }
            if let days = Int(numbers) {
                return days * 1440
            }
        }
        
        if let match = input.range(of: "(\\d+)天前", options: .regularExpression) {
            let matched = String(input[match])
            let numbers = matched.filter { $0.isNumber }
            if let days = Int(numbers) {
                return days * 1440
            }
        }
        
        // 兼容原有的固定格式
        if input.contains("提前10分钟") || input.contains("10分钟前") {
            return 10
        }
        if input.contains("提前30分钟") || input.contains("30分钟前") {
            return 30
        }
        if input.contains("提前1小时") || input.contains("1小时前") {
            return 60
        }
        if input.contains("提前1天") || input.contains("1天前") {
            return 1440
        }
        if input.contains("提前5分钟") || input.contains("5分钟前") {
            return 5
        }
        return nil
    }

    // MARK: - 标题清理

    private static func cleanTitle(_ input: String) -> String {
        var result = input

        // 移除日期关键词
        let dateKeywords = ["明天", "后天", "大后天", "今天", "昨天", "前天"]
        for kw in dateKeywords {
            result = result.replacingOccurrences(of: kw, with: "")
        }

        // 移除颜色关键词
        let colorKeywords = ["红色", "橙色", "黄色", "绿色", "蓝色", "紫色", "粉色", "灰色"]
        for kw in colorKeywords {
            result = result.replacingOccurrences(of: kw, with: "")
        }

        // 移除优先级关键词
        let priorityKeywords = ["重要", "紧急", "高优", "中等", "普通", "低优", "次要"]
        for kw in priorityKeywords {
            result = result.replacingOccurrences(of: kw, with: "")
        }

        // 移除周期关键词
        let recurrenceKeywords = ["每年农历", "每年阴历", "每天", "每周", "每月", "每年", "循环", "重复"]
        for kw in recurrenceKeywords {
            result = result.replacingOccurrences(of: kw, with: "")
        }

        // 移除农历标记（包括农历日期，支持可选空格如"农历 7 月 8 日"）
        if let lunarRange = result.range(of: "(?:农历|阴历)\\s*(?:\\d+)\\s*月\\s*(?:\\d+)\\s*[日号]?", options: .regularExpression) {
            result.removeSubrange(lunarRange)
        }
        result = result.replacingOccurrences(of: "农历", with: "")
        result = result.replacingOccurrences(of: "阴历", with: "")

        // 移除提醒关键词（包括通用模式）
        let reminderKeywords = ["提前10分钟", "提前30分钟", "提前1小时", "提前1天", "提前5分钟",
                               "10分钟前", "30分钟前", "1小时前", "1天前", "5分钟前", "提醒"]
        for kw in reminderKeywords {
            result = result.replacingOccurrences(of: kw, with: "")
        }
        
        // 移除时间表达式，如"下午3点"、"上午9点"、"20:15"、"20点15分"等
        // 先移除 HH:MM 格式
        if let timeRange = result.range(of: "\\d{1,2}:\\d{2}", options: .regularExpression) {
            result.removeSubrange(timeRange)
        }
        // 再移除 X点X分 格式（不带时间段前缀）
        else if let timeRange = result.range(of: "\\d{1,2}点\\d{1,2}(分)?", options: .regularExpression) {
            result.removeSubrange(timeRange)
        }
        // 最后移除带时间段的时间格式
        else if let timeRange = result.range(of: "(上午|下午|晚上|凌晨)?\\d{1,2}点(\\d{1,2}分)?", options: .regularExpression) {
            result.removeSubrange(timeRange)
        }
        
        // 移除相对时间表达式，如"3天后"、"2小时后"、"30分钟后"
        let relativeTimePatterns = [
            "\\d+天后",
            "\\d+小时后", 
            "\\d+分钟后"
        ]
        for pattern in relativeTimePatterns {
            if let range = result.range(of: pattern, options: .regularExpression) {
                result.removeSubrange(range)
            }
        }

        // 清理空白
        result = result.trimmingCharacters(in: .whitespaces)
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }

        return result.isEmpty ? "待办事项" : result
    }
    
    // MARK: - 周期推进
    
    /// 将过去的时间推进到下一个周期的有效时间
    private static func advanceToNextPeriod(date: Date, recurrence: RecurrenceType) -> Date {
        // 复用 CalendarService 的公共逻辑，确保一致性
        return CalendarService.advanceRecurrenceDate(date, recurrenceType: recurrence)
    }
}

/// 解析后的任务数据
struct ParsedTask {
    var title: String
    var date: Date
    var color: EventColor?
    var priority: EventPriority?
    var recurrence: RecurrenceType?
    var isLunar: Bool = false
    var isRecurringLunar: Bool = false
    var reminderMinutes: Int?

    init(title: String, date: Date) {
        self.title = title
        self.date = date
        self.color = nil
        self.priority = nil
        self.recurrence = nil
        self.isLunar = false
        self.isRecurringLunar = false
        self.reminderMinutes = nil
    }
}
