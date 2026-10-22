//
//  NLPTaskParser.swift
//  SwallowCalendar
//

import Foundation

/// 自然语言任务解析器
struct NLPTaskParser {

    // MARK: - 预编译正则表达式
    /// 匹配带时间段的时间格式，如"下午3点"、"晚上8点15分"
    private static let timeRegex: NSRegularExpression = {
        do { return try NSRegularExpression(pattern: "(上午|下午|晚上|凌晨)?(\\d{1,2})点(\\d{1,2})?分?") }
        catch { fatalError("Invalid timeRegex pattern: \(error)") }
    }()
    /// 匹配 X月X日 格式
    private static let dateRegex: NSRegularExpression = {
        do { return try NSRegularExpression(pattern: "(\\d+)月(\\d+)[日号]") }
        catch { fatalError("Invalid dateRegex pattern: \(error)") }
    }()
    /// 农历日期片段 pattern：月序支持"正月/二月/…/冬月(十一月)/腊月(十二月)/数字"，
    /// 日序支持"初一~初十/十一~十九/二十、廿一~廿九/三十/数字"，"日/号"可省略；
    /// 单字日序刻意不含"七"——避免"农历七月七夕"中"七夕"的"七"被误当日序吃掉
    ///（标准表达"七月初七"由"初"分支覆盖、数字格式由 \d 覆盖，不受影响）；
    /// 供 lunarRegex、parseLunarDate 匹配、cleanTitle 清洗三处复用，避免多份 pattern 漂移
    private static let lunarPatternString =
        "(?:农历|阴历)\\s*((?:正|冬|腊|[一二三四五六七八九十]{1,2}|\\d{1,2})\\s*月)\\s*" +
        "(三十|(?:廿|二十)[一二三四五六七八九]?|十[一二三四五六七八九]?|初[一二三四五六七八九十]|[一二三四五六八九]|\\d{1,2})\\s*[日号]?"
    /// 匹配农历日期格式
    private static let lunarRegex: NSRegularExpression = {
        do { return try NSRegularExpression(pattern: lunarPatternString) }
        catch { fatalError("Invalid lunarRegex pattern: \(error)") }
    }()

    // MARK: - 解析用 Calendar（N-15：提为静态常量，避免每次解析重复构造）
    /// "周X/星期X"匹配用：固定周日=1，不受用户 firstWeekday 设置影响
    private static let weekdayCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 1
        return calendar
    }()
    /// 农历日期换算用
    private static let chineseCalendar = Calendar(identifier: .chinese)
    /// 农历解析中公历日期推算用
    private static let gregorianCalendar = Calendar.current

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

        // 对于周期任务，如果时间已经过去，推进到下一个周期（最多推进5次，避免极端情况）
        if let recurrence = result.recurrence, recurrence != .none && result.date < Date() {
            var currentDate = result.date
            let maxAdvances = 5
            for _ in 0..<maxAdvances {
                if currentDate > Date() { break }
                currentDate = advanceToNextPeriod(date: currentDate, recurrence: recurrence)
            }
            result.date = currentDate
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
        // 匹配带时段前缀的时间格式，如"下午3点"、"上午9点"、"晚上8点15分"
        // N-1：带前缀分支必须先于无前缀分支，否则"下午3点30分"被无前缀正则
        // 先拦截解析为 03:30，且带分钟输入令原带前缀分支永不可达
        // E-13：前缀组必选——可选时"晚上开会3点"类输入会从"3点"处匹配而丢失前缀
        else if let timeMatch = input.range(of: "(上午|下午|晚上|凌晨)(\\d{1,2})点(\\d{1,2}分)?", options: .regularExpression) {
            let timeStr = String(input[timeMatch])

            // 使用 NSRegularExpression 捕获组提取小时和分钟（避免 filter 合并数字的问题）
            let timeRegex = Self.timeRegex
            if let match = timeRegex.firstMatch(in: timeStr, range: NSRange(timeStr.startIndex..., in: timeStr)),
               match.numberOfRanges >= 3,
               let hourRange = Range(match.range(at: 2), in: timeStr),
               let hour = Int(timeStr[hourRange]) {

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

                // 提取分钟（第3个捕获组，可选）
                var minute = 0
                if match.numberOfRanges >= 4,
                   let minuteRange = Range(match.range(at: 3), in: timeStr),
                   !minuteRange.isEmpty,
                   let min = Int(timeStr[minuteRange]) {
                    minute = min
                }

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
        // 匹配 X点X分 格式（不带上午/下午前缀，如 20点15, 9点30分；
        // N-1：带前缀场景已由上一分支优先处理，此处自然收窄为无前缀场景）
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
        // 匹配孤立 X点 时间，如"开会3点"、"晚上开会3点"（前缀与时间被文字隔开或无前缀）
        // E-13：原带可选前缀的定位正则在"晚上开会3点"类输入会回溯为空导致前缀丢失，
        // 改为匹配纯时间后检查其前文是否含时段前缀
        else if let timeMatch = input.range(of: "(\\d{1,2})点(\\d{1,2}分)?", options: .regularExpression) {
            let timeStr = String(input[timeMatch])
            // 检查匹配位置之前的文本是否含时段前缀（如"晚上开会3点"的"晚上"）
            let leadingText = String(input[input.startIndex..<timeMatch.lowerBound])

            // 使用 NSRegularExpression 捕获组提取小时和分钟（避免 filter 合并数字的问题）
            let timeRegex = Self.timeRegex
            if let match = timeRegex.firstMatch(in: timeStr, range: NSRange(timeStr.startIndex..., in: timeStr)),
               match.numberOfRanges >= 3,
               let hourRange = Range(match.range(at: 2), in: timeStr),
               let hour = Int(timeStr[hourRange]) {

                var finalHour = hour
                let isAfternoon = leadingText.contains("下午") || leadingText.contains("晚上")
                
                if hour >= 12 {
                    // 如果小时 >= 12，说明已经是24小时制，直接使用
                    finalHour = hour
                } else if isAfternoon {
                    // 小时 < 12 且有下午/晚上标识，加12小时
                    finalHour = hour + 12
                }
                // 其他情况（上午/凌晨或无标识）直接使用原始小时数
                
                // 提取分钟（第3个捕获组，可选）
                var minute = 0
                if match.numberOfRanges >= 4,
                   let minuteRange = Range(match.range(at: 3), in: timeStr),
                   !minuteRange.isEmpty,
                   let min = Int(timeStr[minuteRange]) {
                    minute = min
                }
                
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
            // 使用 NSRegularExpression 捕获组分别提取月和日
            let dateRegex = Self.dateRegex
            if let dateMatch = dateRegex.firstMatch(in: matched, range: NSRange(matched.startIndex..., in: matched)),
               dateMatch.numberOfRanges >= 3,
               let monthRange = Range(dateMatch.range(at: 1), in: matched),
               let dayRange = Range(dateMatch.range(at: 2), in: matched),
               let month = Int(matched[monthRange]),
               let day = Int(matched[dayRange]),
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
        // 使用固定周日=1的Calendar（N-15 静态常量），不受用户firstWeekday设置影响
        let gregorianForWeekday = Self.weekdayCalendar
        
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
        // 匹配"农历X月X日"（月序/日序支持中文与数字，如"正月初一""腊月三十"，"日/号"可省略）
        guard let match = input.range(of: Self.lunarPatternString, options: .regularExpression) else {
            return nil
        }
        
        let matched = String(input[match])
        // 提取月序/日序 token 并转为数字（token 形态已由 pattern 限定，范围校验在转换函数内）
        guard let fullMatch = Self.lunarRegex.firstMatch(in: input, range: NSRange(match, in: input)),
              fullMatch.numberOfRanges >= 3,
              let monthRange = Range(fullMatch.range(at: 1), in: input),
              let dayRange = Range(fullMatch.range(at: 2), in: input),
              let lunarMonth = lunarMonthValue(String(input[monthRange])),
              let lunarDay = lunarDayValue(String(input[dayRange])) else {
            return nil
        }

        // N-15：chineseCalendar/gregorianCalendar 已提为静态常量，逐天搜索直接复用

        // 从今天开始，逐天搜索，最多搜索1年
        // 农历年约354天，1年约365天，性能更好
        var currentDate = Self.gregorianCalendar.startOfDay(for: now)
        let maxDate = Self.gregorianCalendar.date(byAdding: .year, value: 1, to: currentDate)!
        // 最近一个腊月的最后一天（除夕候选），用于"腊月三十不存在"的年份兜底
        var lastTwelfthMonthEnd: Date?

        while currentDate < maxDate {
            // 将公历日期转为农历，检查是否匹配
            let lunarComponents = Self.chineseCalendar.dateComponents([.month, .day], from: currentDate)

            if lunarComponents.month == lunarMonth && lunarComponents.day == lunarDay {
                // 找到匹配的农历日期
                return (currentDate, matched, true)
            }

            // 跟踪腊月末日：今天属农历十二月且明天不再属于（即腊月最后一天）
            if lunarComponents.month == 12,
               Self.chineseCalendar.dateComponents([.month], from: Self.gregorianCalendar.date(byAdding: .day, value: 1, to: currentDate)!).month != 12 {
                lastTwelfthMonthEnd = currentDate
            }

            // 前进一天
            currentDate = Self.gregorianCalendar.date(byAdding: .day, value: 1, to: currentDate)!
        }

        // 腊月三十兜底：小月年份腊月仅 29 天（如 2027 年除夕为 2027-02-05 腊月廿九），
        // 逐天搜索永远找不到"12月30日"，原实现返回 nil 后误走公历解析把"12月30日"
        // 当公历日期；此时映射到该腊月最后一天（除夕语义）
        if lunarMonth == 12, lunarDay == 30, let fallback = lastTwelfthMonthEnd {
            return (fallback, matched, true)
        }

        return nil
    }

    // MARK: - 农历月序/日序换算

    /// 中文数字（一~三十常用表达）转整数：一~九、十、十一~十九、二十/廿、二十一~二十九、三十
    private static func chineseNumeral(_ text: String) -> Int? {
        let digit: [String: Int] = ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5,
                                    "六": 6, "七": 7, "八": 8, "九": 9]
        if let d = digit[text] { return d }
        switch text {
        case "十": return 10
        case "二十", "廿": return 20
        case "三十": return 30
        default: break
        }
        if text.hasPrefix("十"), let d = digit[String(text.dropFirst())] { return 10 + d }
        if text.hasPrefix("廿"), let d = digit[String(text.dropFirst())] { return 20 + d }
        if text.hasPrefix("二十"), let d = digit[String(text.dropFirst(2))] { return 20 + d }
        return nil
    }

    /// 农历月序 token 转数字（1~12）：正月=1、冬月=11、腊月=12，其余中文/数字月序通用换算
    private static func lunarMonthValue(_ token: String) -> Int? {
        // token 内允许空白（如"农历 7 月"），先去除再换算
        let t = token.components(separatedBy: .whitespaces).joined()
        let special = ["正月": 1, "冬月": 11, "腊月": 12]
        if let v = special[t] { return v }
        guard t.hasSuffix("月") else { return nil }
        let body = String(t.dropLast())
        guard let n = Int(body) ?? chineseNumeral(body), (1...12).contains(n) else { return nil }
        return n
    }

    /// 农历日序 token 转数字（1~30）：初X=1~10，其余中文/数字日序通用换算
    private static func lunarDayValue(_ token: String) -> Int? {
        let t = token.components(separatedBy: .whitespaces).joined()
        if let n = Int(t) { return (1...30).contains(n) ? n : nil }
        if t.hasPrefix("初"), let d = chineseNumeral(String(t.dropFirst())) { return d }
        return chineseNumeral(t)
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
        if input.contains("每天") || input.contains("日循环") {
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
        // 孤立"循环"（无周期前缀）默认每日——必须放在周期组合之后，
        // 否则"每年循环"会被无约束 contains("循环") 抢先判为 daily
        if input.contains("循环") {
            return .daily
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
        
        // N-8b：原"兼容固定格式"分支不可达——上方正则 (\d+) 已覆盖全部数字形式
        // （如"提前10分钟"/"10分钟前"），固定字面量必然先被正则命中
        return nil
    }

    // MARK: - 标题清理

    private static func cleanTitle(_ input: String) -> String {
        var result = input

        // 移除日期关键词
        // N-7："大后天"必须在"后天"之前——子串替换会先命中"后天"，
        // 导致"大后天"残留孤立的"大"字
        let dateKeywords = ["明天", "大后天", "后天", "今天", "昨天", "前天"]
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

        // N-6：移除星期词——必须在周期关键词之前，否则"每周一"先移除"每周"后
        // 残留孤立的"一"无法再匹配；正则需同时吞掉前缀"每"，否则"每周一"移除
        // "周一"后残留孤立的"每"字（swift test 暴露）
        if let weekdayRange = result.range(of: "每?(?:星期|周|礼拜)[一二三四五六日天]", options: .regularExpression) {
            result.removeSubrange(weekdayRange)
        }

        // 移除农历标记（含农历日期，月序/日序支持中文与数字）——必须在周期关键词之前：
        // 否则"每年农历"先被移除会丢掉农历前缀，中文日序"正月初一"将无法匹配而残留标题
        //（数字格式原靠下方公历移除兜底，中文表达无数字不适用）
        if let lunarRange = result.range(of: Self.lunarPatternString, options: .regularExpression) {
            result.removeSubrange(lunarRange)
        }
        result = result.replacingOccurrences(of: "农历", with: "")
        result = result.replacingOccurrences(of: "阴历", with: "")

        // 移除周期关键词
        let recurrenceKeywords = ["每天", "每周", "每月", "每年", "循环", "重复"]
        for kw in recurrenceKeywords {
            result = result.replacingOccurrences(of: kw, with: "")
        }

        // N-6：移除公历日期，如"10月21日"、"3月5号"（与 dateRegex 模式一致，需有日/号后缀）
        if let gregorianRange = result.range(of: "\\d+月\\d+[日号]", options: .regularExpression) {
            result.removeSubrange(gregorianRange)
        }

        // N-6：提醒关键词改为通用模式——原仅枚举特定值（提前10/30/5分钟等），
        // "提前15分钟"、"45分钟前"等任意数值残留标题
        let reminderPatterns = ["提前\\d+分钟", "提前\\d+小时", "提前\\d+天",
                                "\\d+分钟前", "\\d+小时前", "\\d+天前", "提醒"]
        for pattern in reminderPatterns {
            result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        
        // 移除时间表达式，如"下午3点"、"上午9点"、"20:15"、"20点15分"等
        // 先移除 HH:MM 格式
        if let timeRange = result.range(of: "\\d{1,2}:\\d{2}", options: .regularExpression) {
            result.removeSubrange(timeRange)
        }
        // 再移除 X点X分 格式（N-1 同源：可选时段前缀需覆盖，否则"下午3点30分开会"
        // 仅命中"3点30分"而残留"下午"，违反 AC-7 标题清洗无残留；分钟数字组保持
        // 必选，否则"20点15开会"这类无"分"字输入只能由本分支完整清除）
        else if let timeRange = result.range(of: "(?:上午|下午|晚上|凌晨)?\\d{1,2}点\\d{1,2}(?:分)?", options: .regularExpression) {
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
