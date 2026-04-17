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

        // 解析日期
        let dateResult = parseChineseDate(trimmed)
        let title = cleanTitle(trimmed)

        var result = ParsedTask(title: title, date: dateResult.date)

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

        // 提取农历标记
        if trimmed.contains("农历") || trimmed.contains("阴历") {
            result.isLunar = true
        }

        // 提取提醒时间
        if let reminderMinutes = parseReminder(from: trimmed) {
            result.reminderMinutes = reminderMinutes
        }

        return result
    }

    /// 解析中文日期
    private static func parseChineseDate(_ input: String) -> (date: Date, matched: String) {
        let calendar = Calendar.current
        let now = Date()

        // 优先匹配精确词
        if input.contains("大后天") {
            let date = calendar.date(byAdding: .day, value: 3, to: calendar.startOfDay(for: now))
            return (date ?? now, "大后天")
        }
        if input.contains("后天") {
            let date = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: now))
            return (date ?? now, "后天")
        }
        if input.contains("明天") {
            let date = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
            return (date ?? now, "明天")
        }

        // 匹配 X天后/小时/分钟后
        if let match = input.range(of: "(\\d+)天后", options: .regularExpression) {
            let matched = String(input[match])
            let numbers = matched.filter { $0.isNumber }
            if let days = Int(numbers) {
                let date = calendar.date(byAdding: .day, value: days, to: now)
                return (date ?? now, matched)
            }
        }
        if let match = input.range(of: "(\\d+)小时后", options: .regularExpression) {
            let matched = String(input[match])
            let numbers = matched.filter { $0.isNumber }
            if let hours = Int(numbers) {
                let date = calendar.date(byAdding: .hour, value: hours, to: now)
                return (date ?? now, matched)
            }
        }
        if let match = input.range(of: "(\\d+)分钟后", options: .regularExpression) {
            let matched = String(input[match])
            let numbers = matched.filter { $0.isNumber }
            if let minutes = Int(numbers) {
                let date = calendar.date(byAdding: .minute, value: minutes, to: now)
                return (date ?? now, matched)
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
                return (date ?? now, matched)
            }
        }

        // 默认今天
        return (now, "")
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
        let recurrenceKeywords = ["每天", "每周", "每月", "每年", "循环", "重复"]
        for kw in recurrenceKeywords {
            result = result.replacingOccurrences(of: kw, with: "")
        }

        // 移除农历标记
        result = result.replacingOccurrences(of: "农历", with: "")
        result = result.replacingOccurrences(of: "阴历", with: "")

        // 移除提醒关键词
        let reminderKeywords = ["提前10分钟", "提前30分钟", "提前1小时", "提前1天", "提前5分钟",
                               "10分钟前", "30分钟前", "1小时前", "1天前", "5分钟前", "提醒"]
        for kw in reminderKeywords {
            result = result.replacingOccurrences(of: kw, with: "")
        }

        // 清理空白
        result = result.trimmingCharacters(in: .whitespaces)
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }

        return result.isEmpty ? "待办事项" : result
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
