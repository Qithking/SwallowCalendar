//
//  LunarCalendarHelper.swift
//  SwallowCalendar
//

import Foundation

/// 农历计算工具，基于系统 Calendar(identifier: .chinese)
struct LunarCalendarHelper {
    private static let chineseCalendar = Calendar(identifier: .chinese)
    private static let gregorian = Calendar(identifier: .gregorian)

    /// 获取指定日期的农历显示文本
    static func lunarString(for date: Date) -> String {
        // 初一显示月份，其他显示日期
        let day = lunarDay(for: date)
        if day == "初一" {
            return lunarMonth(for: date)
        }
        return day
    }

    /// 获取农历月份文本（如"正月"、"二月"）
    static func lunarMonth(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = chineseCalendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月"

        let monthStr = formatter.string(from: date)
        // 转换为传统叫法
        let monthMap: [String: String] = [
            "1月": "正月", "2月": "二月", "3月": "三月", "4月": "四月",
            "5月": "五月", "6月": "六月", "7月": "七月", "8月": "八月",
            "9月": "九月", "10月": "十月", "11月": "冬月", "12月": "腊月",
        ]

        // 检查是否闰月
        let isLeap = isLeapMonth(for: date)
        let result = monthMap[monthStr] ?? monthStr
        return isLeap ? "闰\(result)" : result
    }

    /// 获取农历日期文本（如"初一"、"十五"）
    static func lunarDay(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = chineseCalendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "d"

        let dayStr = formatter.string(from: date)
        guard let day = Int(dayStr) else {
            return ""
        }

        let dayMap = [
            1: "初一", 2: "初二", 3: "初三", 4: "初四", 5: "初五",
            6: "初六", 7: "初七", 8: "初八", 9: "初九", 10: "初十",
            11: "十一", 12: "十二", 13: "十三", 14: "十四", 15: "十五",
            16: "十六", 17: "十七", 18: "十八", 19: "十九", 20: "二十",
            21: "廿一", 22: "廿二", 23: "廿三", 24: "廿四", 25: "廿五",
            26: "廿六", 27: "廿七", 28: "廿八", 29: "廿九", 30: "三十",
        ]

        return dayMap[day] ?? ""
    }

    /// 是否是闰月
    static func isLeapMonth(for date: Date) -> Bool {
        let components = chineseCalendar.dateComponents([.isLeapMonth], from: date)
        return components.isLeapMonth ?? false
    }

    /// 获取完整的农历日期描述
    static func fullLunarString(for date: Date) -> String {
        let month = lunarMonth(for: date)
        let day = lunarDay(for: date)
        return "\(month)\(day)"
    }

    /// 获取天干地支年
    static func heavenlyStemAndEarthlyBranch(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = chineseCalendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "UU年"
        return formatter.string(from: date)
    }
}
