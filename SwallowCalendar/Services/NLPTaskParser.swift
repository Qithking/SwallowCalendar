//
//  NLPTaskParser.swift
//  SwallowCalendar
//

import Foundation

/// 自然语言任务解析器
struct NLPTaskParser {
    /// 解析自然语言输入，返回任务名和日期
    static func parse(_ input: String) -> ParsedTask {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return ParsedTask(title: "", date: Date())
        }

        // 1. 先尝试 NSDataDetector
        if let detected = parseWithDataDetector(trimmed) {
            return detected
        }

        // 2. 尝试自定义中文正则
        if let detected = parseWithChinesePatterns(trimmed) {
            return detected
        }

        // 3. 无法解析时间，默认今天
        return ParsedTask(title: trimmed, date: Date())
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
        // "早上X点" / "上午X点" / "中午X点"
        // "下午X点" / "晚上X点" / "傍晚X点"
        // "X点半" / "X:XX"
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
            ("(\\d+):(\\d+)", { _ in nil }), // 由双捕获处理
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

struct ParsedTask {
    let title: String
    let date: Date
}
