//
//  NLPTaskParser.swift
//  SwallowCalendar
//

import Foundation
// AppLogger 底层为 os.Logger，调用 warning/info 等方法需定义模块可见（与项目其他调用方一致）
import os

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

    // MARK: - 解析用 Calendar
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

        // 只给日期、未给时间的输入默认 09:00（原为当天 00:00，提醒落在半夜）；
        // 输入含显式时间（几点/HH:MM/小时后等）时按输入走，不覆盖
        let parsedDate: Date
        if !dateResult.matched.isEmpty, !Self.containsExplicitTime(dateResult.matched) {
            parsedDate = Self.defaultMorningTime(dateResult.date)
        } else {
            parsedDate = dateResult.date
        }

        var result = ParsedTask(title: title, date: parsedDate)

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
        // 仅当用户显式输入了日期/时间（matched 非空）才执行"已过推进"；
        // 无时间分量输入（如"每天 喝水"）返回 now+空 matched，首期保持今天
        if let recurrence = result.recurrence, recurrence != .none,
           !dateResult.matched.isEmpty && result.date < Date() {
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

    /// 解析结果文本中是否含显式时间表达（用于区分「只给日期」与「日期+时间」）
    private static func containsExplicitTime(_ matched: String) -> Bool {
        let patterns = ["(\\d{1,2}):(\\d{2})", "(\\d{1,2})点", "(\\d+)小时后", "(\\d+)分钟后"]
        return patterns.contains { matched.range(of: $0, options: .regularExpression) != nil }
    }

    /// 只给日期的输入默认落在当天 09:00（保留原日期，仅替换时分秒）
    private static func defaultMorningTime(_ date: Date) -> Date {
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = 9
        components.minute = 0
        components.second = 0
        return calendar.date(from: components) ?? date
    }

    // MARK: - 中文日期解析

    /// 「时段前缀 → 24 小时制」换算：小时 >=12 视为已是 24 小时制；下午/晚上 +12
    private static func resolved24h(hour: Int, isAfternoon: Bool) -> Int {
        if hour >= 12 { return hour }
        return isAfternoon ? hour + 12 : hour
    }

    /// 「时刻拼装到某天」共用收尾：年月日取自 day，时分取入参（秒清零）
    private static func clockDate(hour: Int, minute: Int, on day: Date, calendar: Calendar) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = hour
        components.minute = minute
        components.second = 0
        return calendar.date(from: components)
    }

    /// 「日期换掉、时间保留」合并：把 baseDate 的时分秒安放到新日期上
    private static func mergingTime(of baseDate: Date, onto day: Date, calendar: Calendar) -> Date? {
        var components = calendar.dateComponents([.hour, .minute, .second], from: baseDate)
        components.year = calendar.component(.year, from: day)
        components.month = calendar.component(.month, from: day)
        components.day = calendar.component(.day, from: day)
        return calendar.date(from: components)
    }

    /// 解析中文日期（包括农历）
    /// 拆分为 6 个阶段：农历 → 时间片段 → 相对日词 → X后 → X月X日 → 周词；
    /// 各阶段命中即返回，isLunar 恒 false（农历已由阶段 0 独占处理）
    private static func parseChineseDate(_ input: String) -> (date: Date, matched: String, isLunar: Bool) {
        let calendar = Calendar.current
        let now = Date()

        // 阶段 0：农历优先
        if let lunarResult = parseLunarDate(input, now: now) {
            return lunarResult
        }

        // 阶段 1：时间片段（未命中回落当天 0 点）；matchedText 供词类阶段拼接保留
        let time = parseChineseTimeOfDay(in: input, calendar: calendar, now: now)
        let baseDate: Date
        let matchedText: String
        if let time {
            baseDate = time.date
            matchedText = time.matched
        } else {
            baseDate = calendar.startOfDay(for: now)
            matchedText = ""
        }

        // 阶段 2-6：按优先级逐级匹配，首中即返回
        if let r = parseChineseRelativeDay(input, baseDate: baseDate, matchedText: matchedText, calendar: calendar, now: now) {
            return (r.date, r.matched, false)
        }
        if let r = parseChineseInNDuration(input, baseDate: baseDate, matchedText: matchedText, calendar: calendar, now: now) {
            return (r.date, r.matched, false)
        }
        if let r = parseChineseMonthDay(input, baseDate: baseDate, matchedText: matchedText, calendar: calendar, now: now) {
            return (r.date, r.matched, false)
        }
        if let r = parseChinesePrefixedWeekday(input, baseDate: baseDate, matchedText: matchedText, calendar: calendar, now: now) {
            return (r.date, r.matched, false)
        }
        if let r = parseChineseWeekday(input, baseDate: baseDate, matchedText: matchedText, calendar: calendar, now: now) {
            return (r.date, r.matched, false)
        }

        // 无日期词但有时间片段 → 用时间片段；全无 → 默认此刻
        if !matchedText.isEmpty {
            return (baseDate, matchedText, false)
        }
        return (now, "", false)
    }

    // MARK: 阶段 1：时间片段（正则命中即独占本阶段，内部校验失败不回落他支）

    private typealias ChineseTimeFragment = (date: Date, matched: String)

    /// 时间片段解析入口：HH:MM → 带前缀 X点X分 → 无前缀 X点X分 → 孤立X点；
    /// 带前缀必须先于无前缀，否则"下午3点30分"被无前缀正则拦截
    private static func parseChineseTimeOfDay(in input: String, calendar: Calendar, now: Date) -> ChineseTimeFragment? {
        if input.range(of: "(\\d{1,2}):(\\d{2})", options: .regularExpression) != nil {
            return parseColonTime(in: input, calendar: calendar, now: now)
        }
        if input.range(of: "(上午|下午|晚上|凌晨)(\\d{1,2})点(\\d{1,2}[分点]?)?", options: .regularExpression) != nil {
            return parsePrefixedClockTime(in: input, calendar: calendar, now: now)
        }
        if input.range(of: "(\\d{1,2})点(\\d{1,2})(分)?", options: .regularExpression) != nil {
            return parsePlainClockTime(in: input, calendar: calendar, now: now)
        }
        if input.range(of: "(\\d{1,2})点(\\d{1,2}分)?", options: .regularExpression) != nil {
            return parseIsolatedClockTime(in: input, calendar: calendar, now: now)
        }
        return nil
    }

    /// "20:15" 冒号格式
    private static func parseColonTime(in input: String, calendar: Calendar, now: Date) -> ChineseTimeFragment? {
        guard let timeMatch = input.range(of: "(\\d{1,2}):(\\d{2})", options: .regularExpression) else { return nil }
        let timeStr = String(input[timeMatch])
        let parts = timeStr.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              hour >= 0, hour <= 23, minute >= 0, minute <= 59,
              let date = clockDate(hour: hour, minute: minute, on: calendar.startOfDay(for: now), calendar: calendar) else {
            return nil
        }
        return (date, timeStr)
    }

    /// "下午3点"、"晚上8点15分"
    /// 前缀组必选——可选时"晚上开会3点"类输入会从"3点"处匹配而丢失前缀；
    /// 口语时间：分钟单位兼容"分/点"（"晚上7点30点"把"分"读作"点"）或省略单位
    ///（"晚上7点30"）；与 cleanTitle 清洗范围保持一致
    private static func parsePrefixedClockTime(in input: String, calendar: Calendar, now: Date) -> ChineseTimeFragment? {
        guard let timeMatch = input.range(of: "(上午|下午|晚上|凌晨)(\\d{1,2})点(\\d{1,2}[分点]?)?", options: .regularExpression) else { return nil }
        let timeStr = String(input[timeMatch])
        // 捕获组提取小时（避免 filter 合并数字的问题）；第 3 组分钟可选
        guard let match = Self.timeRegex.firstMatch(in: timeStr, range: NSRange(timeStr.startIndex..., in: timeStr)),
              match.numberOfRanges >= 3,
              let hourRange = Range(match.range(at: 2), in: timeStr),
              let hour = Int(timeStr[hourRange]) else {
            return nil
        }
        let isAfternoon = timeStr.contains("下午") || timeStr.contains("晚上")
        var minute = 0
        if match.numberOfRanges >= 4,
           let minuteRange = Range(match.range(at: 3), in: timeStr),
           !minuteRange.isEmpty,
           let min = Int(timeStr[minuteRange]) {
            minute = min
        }
        guard let date = clockDate(hour: resolved24h(hour: hour, isAfternoon: isAfternoon), minute: minute, on: calendar.startOfDay(for: now), calendar: calendar) else {
            return nil
        }
        return (date, timeStr)
    }

    /// "20点15"、"9点30分"（带前缀场景已由上一分支优先处理，此处自然收窄为无前缀）
    private static func parsePlainClockTime(in input: String, calendar: Calendar, now: Date) -> ChineseTimeFragment? {
        guard let timeMatch = input.range(of: "(\\d{1,2})点(\\d{1,2})(分)?", options: .regularExpression) else { return nil }
        let timeStr = String(input[timeMatch])
        // 正则逐个提取数字（"20点15" → [20, 15]）
        let numberPattern = "(\\d+)"
        var numbers: [Int] = []
        var searchRange = timeStr.startIndex..<timeStr.endIndex
        while let match = timeStr.range(of: numberPattern, options: .regularExpression, range: searchRange) {
            if let num = Int(timeStr[match]) {
                numbers.append(num)
            }
            searchRange = match.upperBound..<timeStr.endIndex
        }
        guard numbers.count >= 2,
              let hour = numbers.first, let minute = numbers.last,
              hour >= 0, hour <= 23, minute >= 0, minute <= 59,
              let date = clockDate(hour: hour, minute: minute, on: calendar.startOfDay(for: now), calendar: calendar) else {
            return nil
        }
        return (date, timeStr)
    }

    /// "开会3点"：匹配纯时间后检查前文是否含时段前缀（前缀与时间被文字隔开）
    private static func parseIsolatedClockTime(in input: String, calendar: Calendar, now: Date) -> ChineseTimeFragment? {
        guard let timeMatch = input.range(of: "(\\d{1,2})点(\\d{1,2}分)?", options: .regularExpression) else { return nil }
        let timeStr = String(input[timeMatch])
        let leadingText = String(input[input.startIndex..<timeMatch.lowerBound])
        guard let match = Self.timeRegex.firstMatch(in: timeStr, range: NSRange(timeStr.startIndex..., in: timeStr)),
              match.numberOfRanges >= 3,
              let hourRange = Range(match.range(at: 2), in: timeStr),
              let hour = Int(timeStr[hourRange]) else {
            return nil
        }
        let isAfternoon = leadingText.contains("下午") || leadingText.contains("晚上")
        var minute = 0
        if match.numberOfRanges >= 4,
           let minuteRange = Range(match.range(at: 3), in: timeStr),
           !minuteRange.isEmpty,
           let min = Int(timeStr[minuteRange]) {
            minute = min
        }
        guard let date = clockDate(hour: resolved24h(hour: hour, isAfternoon: isAfternoon), minute: minute, on: calendar.startOfDay(for: now), calendar: calendar) else {
            return nil
        }
        return (date, timeStr)
    }

    // MARK: 阶段 2：相对日词（大后天/后天/明天/今天；词表顺序保证"大后天"先于"后天"匹配）

    private static func parseChineseRelativeDay(_ input: String, baseDate: Date, matchedText: String, calendar: Calendar, now: Date) -> (date: Date, matched: String)? {
        for (offset, keyword) in [(3, "大后天"), (2, "后天"), (1, "明天")] {
            guard input.contains(keyword) else { continue }
            guard let d = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) else {
                return (now, keyword)
            }
            // 已有时间片段则换日期保留时间；合并失败回落日期词当天
            if let finalDate = mergingTime(of: baseDate, onto: d, calendar: calendar) {
                return (finalDate, keyword + matchedText)
            }
            return (d, keyword)
        }
        if input.contains("今天") {
            if !matchedText.isEmpty {
                return (baseDate, "今天" + matchedText)
            }
            return (calendar.startOfDay(for: now), "今天")
        }
        return nil
    }

    // MARK: 阶段 3：X天后/小时后/分钟后（原三段顺序 if 非互斥；天后段带时间合并，余两段此刻起算）

    private static func parseChineseInNDuration(_ input: String, baseDate: Date, matchedText: String, calendar: Calendar, now: Date) -> (date: Date, matched: String)? {
        if let match = input.range(of: "(\\d+)天后", options: .regularExpression) {
            let matched = String(input[match])
            if let days = Int(matched.filter { $0.isNumber }) {
                let d = calendar.date(byAdding: .day, value: days, to: now)
                if let dd = d, let finalDate = mergingTime(of: baseDate, onto: dd, calendar: calendar) {
                    return (finalDate, matched + matchedText)
                }
                return (d ?? now, matched)
            }
        }
        if let match = input.range(of: "(\\d+)小时后", options: .regularExpression) {
            let matched = String(input[match])
            if let hours = Int(matched.filter { $0.isNumber }) {
                return (calendar.date(byAdding: .hour, value: hours, to: now) ?? now, matched)
            }
        }
        if let match = input.range(of: "(\\d+)分钟后", options: .regularExpression) {
            let matched = String(input[match])
            if let minutes = Int(matched.filter { $0.isNumber }) {
                return (calendar.date(byAdding: .minute, value: minutes, to: now) ?? now, matched)
            }
        }
        return nil
    }

    // MARK: 阶段 4：X月X日（钳制 + 过去则顺延一年 + 时间合并）

    private static func parseChineseMonthDay(_ input: String, baseDate: Date, matchedText: String, calendar: Calendar, now: Date) -> (date: Date, matched: String)? {
        guard let match = input.range(of: "(\\d+)月(\\d+)[日号]", options: .regularExpression) else { return nil }
        let matched = String(input[match])
        guard let dateMatch = Self.dateRegex.firstMatch(in: matched, range: NSRange(matched.startIndex..., in: matched)),
              dateMatch.numberOfRanges >= 3,
              let monthRange = Range(dateMatch.range(at: 1), in: matched),
              let dayRange = Range(dateMatch.range(at: 2), in: matched),
              let month = Int(matched[monthRange]), let day = Int(matched[dayRange]),
              month >= 1, month <= 12, day >= 1, day <= 31 else {
            return nil
        }
        var components = calendar.dateComponents([.year], from: now)
        components.month = month
        components.day = day
        // 不存在日期（2月30日/4月31日）经钳制回退该月最后一天，不返回 nil
        var date = Self.clampedCalendarDate(components, calendar: calendar)
        if let d = date, d < calendar.startOfDay(for: now) {
            components.year = (components.year ?? 2026) + 1
            date = Self.clampedCalendarDate(components, calendar: calendar)
        }
        if let d = date, let finalDate = mergingTime(of: baseDate, onto: d, calendar: calendar) {
            return (finalDate, matched + matchedText)
        }
        return (date ?? now, matched)
    }

    // MARK: 阶段 5：上/本/下周 + 星期X（普通星期词无法表达过去或明确周次）

    private static func parseChinesePrefixedWeekday(_ input: String, baseDate: Date, matchedText: String, calendar: Calendar, now: Date) -> (date: Date, matched: String)? {
        guard let weekRange = input.range(of: "(上|本|下)个?(星期|周|礼拜)[一二三四五六日天]", options: .regularExpression) else { return nil }
        let matched = String(input[weekRange])
        let prefix = String(matched.prefix(1))
        let weekdayChar = String(matched.suffix(1))
        let weekdayMap: [String: Int] = ["日": 1, "天": 1, "一": 2, "二": 3, "三": 4, "四": 5, "五": 6, "六": 7]
        guard let targetWeekday = weekdayMap[weekdayChar] else { return nil }
        // 周一为周首，本周起点 = 当前周周一 0 点
        var weekCal = Self.weekdayCalendar
        weekCal.firstWeekday = 2
        let weekStart = weekCal.dateInterval(of: .weekOfYear, for: now)?.start ?? weekCal.startOfDay(for: now)
        let offsetInWeek = (targetWeekday + 5) % 7  // 周一=0 … 周日=6
        let weekOffset = prefix == "上" ? -7 : (prefix == "下" ? 7 : 0)
        if let d = weekCal.date(byAdding: .day, value: offsetInWeek + weekOffset, to: weekStart),
           let finalDate = mergingTime(of: baseDate, onto: d, calendar: weekCal) {
            return (finalDate, matched + matchedText)
        }
        return (weekStart, matched)
    }

    // MARK: 阶段 6：星期X/周X（固定周日=1；取最近未来，今天已过时刻顺延一周）

    private static func parseChineseWeekday(_ input: String, baseDate: Date, matchedText: String, calendar: Calendar, now: Date) -> (date: Date, matched: String)? {
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
            guard input.contains(item.keyword) else { continue }
            // 找到最近的该星期几
            let currentWeekday = gregorianForWeekday.component(.weekday, from: now)
            var daysToAdd = item.targetWeekday - currentWeekday
            if daysToAdd < 0 {
                // 目标星期几已经过去，加 7 天到下周
                daysToAdd += 7
            } else if daysToAdd == 0 {
                // 今天就是目标星期几：已带时间片段且时刻已过 → 顺延一周
                if !matchedText.isEmpty {
                    let timeComponents = gregorianForWeekday.dateComponents([.hour, .minute], from: baseDate)
                    if let hour = timeComponents.hour, let minute = timeComponents.minute {
                        var timeDateComponents = gregorianForWeekday.dateComponents([.year, .month, .day], from: now)
                        timeDateComponents.hour = hour
                        timeDateComponents.minute = minute
                        if let timeDate = gregorianForWeekday.date(from: timeDateComponents), timeDate < now {
                            daysToAdd += 7
                        }
                    }
                }
                // 无时间片段或时刻未到，daysToAdd 保持 0（今天）
            }
            let targetDate = gregorianForWeekday.date(byAdding: .day, value: daysToAdd, to: gregorianForWeekday.startOfDay(for: now))
            if let d = targetDate, let finalDate = mergingTime(of: baseDate, onto: d, calendar: gregorianForWeekday) {
                return (finalDate, item.keyword + matchedText)
            }
            return (targetDate ?? now, item.keyword)
        }
        return nil
    }

    /// 公历日期构造——day 超出该月实际天数（如 2月30日）时钳制到该月最后一天。
    /// 注意 Calendar.date(from:) 对溢出 day 是 lenient 顺延（2月30日→3月2日）而非返回 nil，
    /// 故需校验构造结果确实落在请求的月/日，否则钳制
    private static func clampedCalendarDate(_ components: DateComponents, calendar: Calendar) -> Date? {
        guard let month = components.month, let day = components.day else {
            return calendar.date(from: components)
        }
        if let date = calendar.date(from: components),
           calendar.component(.month, from: date) == month,
           calendar.component(.day, from: date) == day {
            return date
        }
        // lenient 顺延或构造失败：从下月1日回退1天得到本月最后一天
        var nextMonth = components
        nextMonth.day = 1
        if month == 12 {
            nextMonth.month = 1
            nextMonth.year = (nextMonth.year ?? 0) + 1
        } else {
            nextMonth.month = month + 1
        }
        guard let firstOfNext = calendar.date(from: nextMonth) else { return calendar.date(from: components) }
        return calendar.date(byAdding: .day, value: -1, to: firstOfNext)
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
        // 逐天搜索永远找不到"12月30日"，返回 nil 会误走公历解析；此时映射到
        // 该腊月最后一天（除夕语义）
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
        // 否定式必须先判——"不重要"包含"重要"
        if input.contains("不是很重要") || input.contains("不太重要") || input.contains("不重要") {
            return .low
        }
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

    /// 提前量收敛到安全上限（±365 天），解除原 1440 分钟（1 天）业务钳制——
    /// 2天前及以上档位可完整解析并进入调度窗口
    private static func parseReminder(from input: String) -> Int? {
        guard let raw = parseReminderUnclamped(from: input) else { return nil }
        let capped = min(max(raw, 0), CachedEvent.maxReminderLeadMinutes)
        if capped != raw {
            AppLogger.reminder.warning("提醒提前量超安全上限已收敛 raw=\(raw) capped=\(capped)")
        }
        return capped
    }

    private static func parseReminderUnclamped(from input: String) -> Int? {
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
        
        return nil
    }

    // MARK: - 标题清理

    private static func cleanTitle(_ input: String) -> String {
        var result = input

        // 移除日期关键词
        // "大后天"必须在"后天"之前——子串替换会先命中"后天"，
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

        // 移除优先级关键词（否定式在前，先整体移除"不重要"，再处理"重要"）
        let priorityKeywords = ["不是很重要", "不太重要", "不重要", "重要", "紧急", "高优", "中等", "普通", "低优", "次要"]
        for kw in priorityKeywords {
            result = result.replacingOccurrences(of: kw, with: "")
        }

        // 移除星期词——必须在周期关键词之前，否则"每周一"先移除"每周"后
        // 残留孤立的"一"无法再匹配；正则需同时吞掉前缀"每"，否则"每周一"移除
        // "周一"后残留孤立的"每"字
        // 同时吞掉"上周/本周/下周"前缀（含"个"），避免残留前缀字
        if let weekdayRange = result.range(of: "(?:[上本下]个?|每)?(?:星期|周|礼拜)[一二三四五六日天]", options: .regularExpression) {
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

        // 移除公历日期，如"10月21日"、"3月5号"（与 dateRegex 模式一致，需有日/号后缀）
        if let gregorianRange = result.range(of: "\\d+月\\d+[日号]", options: .regularExpression) {
            result.removeSubrange(gregorianRange)
        }

        // 提醒关键词用通用模式匹配任意数值——仅枚举特定值会残留"提前15分钟"、"45分钟前"
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
        // 再移除 X点X分 格式（可选时段前缀需覆盖，否则"下午3点30分开会"
        // 仅命中"3点30分"而残留"下午"；分钟数字组保持必选，否则
        // "20点15开会"这类无"分"字输入只能由本分支完整清除）；
        // 分钟单位兼容"分/点"（口语"晚上7点30点下班"），否则清洗后残留"点下班"
        else if let timeRange = result.range(of: "(?:上午|下午|晚上|凌晨)?\\d{1,2}点\\d{1,2}[分点]?", options: .regularExpression) {
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
        return CalendarService.advanceRecurrenceDate(date, recurrenceType: recurrence, origin: date)
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
