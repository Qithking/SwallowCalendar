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

        // 1. 先尝试 NSDataDetector
        if let detected = parseWithDataDetector(trimmed) {
            return mergeAdditionalAttributes(from: trimmed, to: detected)
        }

        // 2. 尝试自定义中文正则
        if let detected = parseWithChinesePatterns(trimmed) {
            return mergeAdditionalAttributes(from: trimmed, to: detected)
        }

        // 3. 无法解析时间，默认今天
        return ParsedTask(title: trimmed, date: Date())
    }

    /// 从输入中提取颜色、优先级、周期等属性
    private static func mergeAdditionalAttributes(from input: String, to task: ParsedTask) -> ParsedTask {
        var result = task

        // 提取颜色
        if let color = parseColor(from: input) {
            result.color = color
        }

        // 提取优先级
        if let priority = parsePriority(from: input) {
            result.priority = priority
        }

        // 提取周期
        if let recurrence = parseRecurrence(from: input) {
            result.recurrence = recurrence
        }

        // 提取农历标记
        if input.contains("农历") || input.contains("阴历") {
            result.isLunar = true
        }

        // 提取提醒时间（提前X分钟/小时/天提醒）
        if let reminderMinutes = parseReminder(from: input) {
            result.reminderMinutes = reminderMinutes
        }

        // 清理标题中的属性关键词
        result.title = cleanTitle(input, removingAttributes: true)

        return result
    }

    // MARK: - 颜色解析

    private static func parseColor(from input: String) -> EventColor? {
        let colorPatterns: [(String, EventColor)] = [
            ("红色|红", .red),
            ("橙色|橙", .orange),
            ("黄色|黄", .yellow),
            ("绿色|绿", .green),
            ("蓝色|蓝", .blue),
            ("紫色|紫", .purple),
            ("粉色|粉", .pink),
            ("灰色|灰", .gray),
        ]

        for (pattern, color) in colorPatterns {
            if input.contains(pattern) {
                return color
            }
        }
        return nil
    }

    // MARK: - 优先级解析

    private static func parsePriority(from input: String) -> EventPriority? {
        let highPatterns = ["重要", "紧急", "高优", "最高", "必须", "关键", "!!!", "!!", "!!!", "[!]", "(!)", "★"]
        let mediumPatterns = ["中等", "普通", "一般"]
        let lowPatterns = ["低优", "低优先级", "次要", "可选", "不重要"]

        for pattern in highPatterns {
            if input.contains(pattern) { return .high }
        }
        for pattern in mediumPatterns {
            if input.contains(pattern) { return .medium }
        }
        for pattern in lowPatterns {
            if input.contains(pattern) { return .low }
        }

        return nil
    }

    // MARK: - 周期解析

    private static func parseRecurrence(from input: String) -> RecurrenceType? {
        if input.contains("每天") || input.contains("日循环") {
            return .daily
        }
        if input.contains("每周") || input.contains("周循环") {
            return .weekly
        }
        if input.contains("每月") || input.contains("月循环") {
            return .monthly
        }
        if input.contains("每年") || input.contains("年循环") || input.contains("周年") {
            return .yearly
        }
        if input.contains("循环") || input.contains("重复") || input.contains("不限") {
            return .daily
        }
        return nil
    }

    // MARK: - 提醒时间解析

    private static func parseReminder(from input: String) -> Int? {
        // "提前X分钟提醒"
        if let match = input.range(of: "提前(\\d+)分钟", options: .regularExpression) {
            let numbers = input[match].filter { $0.isNumber }
            return Int(numbers)
        }
        // "提前X小时提醒"
        if let match = input.range(of: "提前(\\d+)小时", options: .regularExpression) {
            let numbers = input[match].filter { $0.isNumber }
            return (Int(numbers) ?? 0) * 60
        }
        // "提前X天提醒"
        if let match = input.range(of: "提前(\\d+)天", options: .regularExpression) {
            let numbers = input[match].filter { $0.isNumber }
            return (Int(numbers) ?? 0) * 1440
        }
        return nil
    }

    // MARK: - 标题清理

    private static func cleanTitle(_ input: String, removingAttributes: Bool) -> String {
        var result = input

        if removingAttributes {
            // 移除颜色关键词
            let colorKeywords = ["红色", "红", "橙色", "橙", "黄色", "黄", "绿色", "绿",
                                  "蓝色", "蓝", "紫色", "紫", "粉色", "粉", "灰色", "灰"]
            for kw in colorKeywords {
                result = result.replacingOccurrences(of: kw, with: "")
            }

            // 移除优先级关键词
            let priorityKeywords = ["重要", "紧急", "高优", "最高", "必须", "关键", "中等", "普通",
                                     "一般", "低优", "低优先级", "次要", "可选", "不重要"]
            for kw in priorityKeywords {
                result = result.replacingOccurrences(of: kw, with: "")
            }

            // 移除优先级符号
            let prioritySymbols = ["!!!", "!!", "!", "[!]", "(!)", "★"]
            for sym in prioritySymbols {
                result = result.replacingOccurrences(of: sym, with: "")
            }

            // 移除周期关键词
            let recurrenceKeywords = ["每天", "每周", "每月", "每年", "循环", "重复", "不限"]
            for kw in recurrenceKeywords {
                result = result.replacingOccurrences(of: kw, with: "")
            }

            // 移除农历标记
            result = result.replacingOccurrences(of: "农历", with: "")
            result = result.replacingOccurrences(of: "阴历", with: "")

            // 移除提醒时间关键词
            if let range = result.range(of: "提前\\d+分钟", options: .regularExpression) {
                result.removeSubrange(range)
            }
            if let range = result.range(of: "提前\\d+小时", options: .regularExpression) {
                result.removeSubrange(range)
            }
            if let range = result.range(of: "提前\\d+天", options: .regularExpression) {
                result.removeSubrange(range)
            }
            result = result.replacingOccurrences(of: "提醒", with: "")
        }

        // 清理空白
        result = result.trimmingCharacters(in: .whitespaces)
        // 清理多余空格
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }

        return result.isEmpty ? "待办事项" : result
    }

    // MARK: - NSDataDetector

    private static func parseWithDataDetector(_ input: String) -> ParsedTask? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return nil
        }

        let range = NSRange(input.startIndex..., in: input)
        let matches = detector.matches(in: input, range: range)

        guard let firstMatch = matches.first,
              let date = firstMatch.date else {
            return nil
        }

        let matchedRange = firstMatch.range
        let matchedString = String(input[Range(matchedRange, in: input)!])
        let title = input.replacingOccurrences(of: matchedString, with: "")
            .trimmingCharacters(in: .whitespaces)

        return ParsedTask(title: title.isEmpty ? input : title, date: date)
    }

    // MARK: - Chinese Patterns

    private static func parseWithChinesePatterns(_ input: String) -> ParsedTask? {
        let calendar = Calendar.current
        let now = Date()
        var resultDate: Date?
        var matchedPattern: String?

        // 定义中文时间模式及其解析器
        let patterns: [(String, (String) -> Date?)] = [
            // "X天后"
            ("(\\d+)天后", { match in
                guard let days = Int(match) else { return nil }
                return calendar.date(byAdding: .day, value: days, to: now)
            }),
            // "X小时后"
            ("(\\d+)小时后", { match in
                guard let hours = Int(match) else { return nil }
                return calendar.date(byAdding: .hour, value: hours, to: now)
            }),
            // "X分钟后"
            ("(\\d+)分钟后", { match in
                guard let minutes = Int(match) else { return nil }
                return calendar.date(byAdding: .minute, value: minutes, to: now)
            }),
            // "明天"
            ("明天", { _ in
                calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
            }),
            // "后天"
            ("后天", { _ in
                calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: now))
            }),
            // "大后天"
            ("大后天", { _ in
                calendar.date(byAdding: .day, value: 3, to: calendar.startOfDay(for: now))
            }),
            // "下周X"
            ("下周([一二三四五六日天])", { match in
                let weekdayMap: [String: Int] = ["一": 2, "二": 3, "三": 4, "四": 5, "五": 6, "六": 7, "日": 1, "天": 1]
                guard let targetWeekday = weekdayMap[match] else { return nil }
                return nextWeekday(targetWeekday)
            }),
            // "本周X" / "这周X"
            ("(?:本周|这周)([一二三四五六日天])", { match in
                let weekdayMap: [String: Int] = ["一": 2, "二": 3, "三": 4, "四": 5, "五": 6, "六": 7, "日": 1, "天": 1]
                guard let targetWeekday = weekdayMap[match] else { return nil }
                return thisWeekWeekday(targetWeekday)
            }),
            // "下个月X号"
            ("下个月(\\d+)号?", { match in
                guard let day = Int(match), day >= 1, day <= 31 else { return nil }
                var components = calendar.dateComponents([.year, .month], from: now)
                components.month = (components.month ?? 1) + 1
                components.day = day
                return calendar.date(from: components)
            }),
        ]

        // 双捕获组模式特殊处理
        let dualCapturePatterns: [(String, (String, String) -> Date?)] = [
            // "X月X日" / "X月X号"
            ("(\\d+)月(\\d+)[日号]", { monthStr, dayStr in
                guard let month = Int(monthStr), let day = Int(dayStr),
                      month >= 1, month <= 12, day >= 1, day <= 31 else { return nil }
                var components = calendar.dateComponents([.year], from: now)
                components.month = month
                components.day = day
                let date = calendar.date(from: components)
                // 如果日期已过，则算明年
                if let date, date < calendar.startOfDay(for: now) {
                    components.year = (components.year ?? 2026) + 1
                    return calendar.date(from: components)
                }
                return date
            }),
        ]

        // 时间后缀模式（可以和上面组合）
        let timeSuffixPatterns: [(String, (String) -> (hour: Int, minute: Int)?)] = [
            ("(?:早上|上午)(\\d+)(?:点(\\d+)分?)?(?:点半)?", { match in
                guard let hour = Int(match), hour >= 0, hour <= 23 else { return nil }
                return (hour, 0)
            }),
            ("中午(\\d+)(?:点(\\d+)分?)?(?:点半)?", { match in
                guard let hour = Int(match), hour >= 0, hour <= 23 else { return nil }
                return (hour, 0)
            }),
            ("(?:下午|晚上|傍晚)(\\d+)(?:点(\\d+)分?)?(?:点半)?", { match in
                guard let hour = Int(match), hour >= 1, hour <= 12 else { return nil }
                return (hour + 12, 0)
            }),
            ("(\\d+)点半", { match in
                guard let hour = Int(match), hour >= 0, hour <= 23 else { return nil }
                return (hour, 30)
            }),
            ("(\\d+):(\\d+)", { _ in nil }),
        ]

        let dualTimePatterns: [(String, (String, String) -> (hour: Int, minute: Int)?)] = [
            ("(?:下午|晚上|傍晚)(\\d+)点(\\d+)分?", { hourStr, minuteStr in
                guard let hour = Int(hourStr), let minute = Int(minuteStr),
                      hour >= 1, hour <= 12 else { return nil }
                return (hour + 12, minute)
            }),
            ("(?:早上|上午|中午)(\\d+)点(\\d+)分?", { hourStr, minuteStr in
                guard let hour = Int(hourStr), let minute = Int(minuteStr),
                      hour >= 0, hour <= 23 else { return nil }
                return (hour, minute)
            }),
            ("(\\d+):(\\d+)", { hourStr, minuteStr in
                guard let hour = Int(hourStr), let minute = Int(minuteStr),
                      hour >= 0, hour <= 23, minute >= 0, minute <= 59 else { return nil }
                return (hour, minute)
            }),
        ]

        // 尝试单捕获组模式
        for (pattern, parser) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
               let range = Range(match.range(at: 1), in: input) {
                let captured = String(input[range])
                if let date = parser(captured) {
                    resultDate = date
                    matchedPattern = String(input[Range(match.range, in: input)!])
                    break
                }
            }
        }

        // 尝试双捕获组模式
        if resultDate == nil {
            for (pattern, parser) in dualCapturePatterns {
                if let regex = try? NSRegularExpression(pattern: pattern),
                   let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
                   let range1 = Range(match.range(at: 1), in: input),
                   let range2 = Range(match.range(at: 2), in: input) {
                    let captured1 = String(input[range1])
                    let captured2 = String(input[range2])
                    if let date = parser(captured1, captured2) {
                        resultDate = date
                        matchedPattern = String(input[Range(match.range, in: input)!])
                        break
                    }
                }
            }
        }

        // 尝试添加时间部分
        if var date = resultDate {
            for (pattern, parser) in timeSuffixPatterns {
                if let regex = try? NSRegularExpression(pattern: pattern),
                   let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
                   let range = Range(match.range(at: 1), in: input) {
                    let captured = String(input[range])
                    if let time = parser(captured) {
                        date = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: date) ?? date
                        if matchedPattern == nil {
                            matchedPattern = String(input[Range(match.range, in: input)!])
                        }
                        break
                    }
                }
            }

            for (pattern, parser) in dualTimePatterns {
                if let regex = try? NSRegularExpression(pattern: pattern),
                   let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
                   let range1 = Range(match.range(at: 1), in: input),
                   let range2 = Range(match.range(at: 2), in: input) {
                    let captured1 = String(input[range1])
                    let captured2 = String(input[range2])
                    if let time = parser(captured1, captured2) {
                        date = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: date) ?? date
                        if matchedPattern == nil {
                            matchedPattern = String(input[Range(match.range, in: input)!])
                        }
                        break
                    }
                }
            }

            // 提取标题：移除匹配到的时间部分
            var title = input
            if let pattern = matchedPattern {
                title = title.replacingOccurrences(of: pattern, with: "")
            }
            title = title.trimmingCharacters(in: .whitespaces)
            if title.isEmpty { title = "待办事项" }

            return ParsedTask(title: title, date: date)
        }

        return nil
    }

    // MARK: - Helpers

    private static func nextWeekday(_ target: Int) -> Date? {
        let calendar = Calendar.current
        let now = Date()
        let currentWeekday = calendar.component(.weekday, from: now)

        var daysToAdd = target - currentWeekday
        if daysToAdd <= 0 { daysToAdd += 7 }

        return calendar.date(byAdding: .day, value: daysToAdd, to: calendar.startOfDay(for: now))
    }

    private static func thisWeekWeekday(_ target: Int) -> Date? {
        let calendar = Calendar.current
        let now = Date()
        let currentWeekday = calendar.component(.weekday, from: now)

        var daysToAdd = target - currentWeekday
        if daysToAdd < 0 { daysToAdd += 7 }

        return calendar.date(byAdding: .day, value: daysToAdd, to: calendar.startOfDay(for: now))
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
    var reminderMinutes: Int?

    init(title: String, date: Date) {
        self.title = title
        self.date = date
        self.color = nil
        self.priority = nil
        self.recurrence = nil
        self.isLunar = false
        self.reminderMinutes = nil
    }
}
