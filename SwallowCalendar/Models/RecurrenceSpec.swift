//
//  RecurrenceSpec.swift
//  SwallowCalendar
//
//  循环规则的单一真源：与 macOS「提醒事项」的 12 项预设一一对应，
//  同时承担本地展开、完成推进与 EventKit 正/反向映射。
//

import Foundation
import EventKit

// MARK: - 频率

enum RecurrenceFrequency: String, Codable, CaseIterable, Hashable {
    case hourly
    case daily
    case weekly
    case monthly
    case yearly

    var displayName: String {
        switch self {
        case .hourly: return "小时"
        case .daily: return "天"
        case .weekly: return "周"
        case .monthly: return "个月"
        case .yearly: return "年"
        }
    }
}

// MARK: - 每月/每年「第 N 个周几」

struct NthWeekday: Codable, Hashable {
    /// 1...5，-1 = 最后一个
    var nth: Int
    /// Calendar weekday：1=周日 ... 7=周六
    var weekday: Int

    var displayName: String {
        let weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let index = min(max(weekday, 1), 7) - 1
        let nthText: String
        switch nth {
        case -1: nthText = "最后一个"
        case 1: nthText = "第一个"
        case 2: nthText = "第二个"
        case 3: nthText = "第三个"
        case 4: nthText = "第四个"
        case 5: nthText = "第五个"
        default: nthText = "第\(nth)个"
        }
        return "\(nthText)\(weekdays[index])"
    }
}

// MARK: - 结束重复

struct RecurrenceEndRule: Codable, Hashable {
    enum Mode: String, Codable { case never, date, count }

    var mode: Mode = .never
    var date: Date?
    var count: Int?

    static let never = RecurrenceEndRule(mode: .never)
    static func on(_ date: Date) -> RecurrenceEndRule {
        RecurrenceEndRule(mode: .date, date: date)
    }
    static func after(_ count: Int) -> RecurrenceEndRule {
        RecurrenceEndRule(mode: .count, count: count)
    }
}

// MARK: - RecurrenceSpec

struct RecurrenceSpec: Codable, Hashable {
    var frequency: RecurrenceFrequency
    /// 每 N 个频率单位，≥1
    var interval: Int = 1
    /// 每周多选星期（1=周日 ... 7=周六）；空 = 沿用起始日星期
    var weekdays: [Int] = []
    /// 每月/每年「按日期」（1...31）
    var monthDay: Int?
    /// 每月/每年「第 N 个周几」；与 monthDay 互斥
    var nthWeekday: NthWeekday?
    /// 每年月份（1...12）；空 = 起始日月份
    var months: [Int] = []
    var end: RecurrenceEndRule = .never

    init(
        frequency: RecurrenceFrequency,
        interval: Int = 1,
        weekdays: [Int] = [],
        monthDay: Int? = nil,
        nthWeekday: NthWeekday? = nil,
        months: [Int] = [],
        end: RecurrenceEndRule = .never
    ) {
        self.frequency = frequency
        self.interval = max(1, interval)
        self.weekdays = Array(Set(weekdays)).sorted()
        self.monthDay = monthDay.map { min(max($0, 1), 31) }
        self.nthWeekday = nthWeekday
        self.months = Array(Set(months)).sorted()
        self.end = end
    }

    // MARK: 持久化

    var jsonString: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ json: String?) -> RecurrenceSpec? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RecurrenceSpec.self, from: data)
    }

    static func jsonEquals(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (decode(lhs), decode(rhs)) {
        case (nil, nil): return true
        case let (l?, r?): return l == r
        default: return false
        }
    }

    // MARK: 旧档位推导（存量零变化）

    /// 旧 `RecurrenceType` → spec；`.custom` 旧行返回 nil（保持「不可展开」历史语义）
    static func legacy(from type: RecurrenceType, anchor: Date, isLunar: Bool) -> RecurrenceSpec? {
        let calendar = Calendar.current
        let day = calendar.component(.day, from: anchor)
        let month = calendar.component(.month, from: anchor)
        switch type {
        case .none, .custom:
            return nil
        case .unlimited, .daily:
            return RecurrenceSpec(frequency: .daily, interval: 1, monthDay: nil)
        case .hourly:
            return RecurrenceSpec(frequency: .hourly, interval: 1)
        case .weekly:
            return RecurrenceSpec(frequency: .weekly, interval: 1)
        case .monthly:
            return RecurrenceSpec(frequency: .monthly, interval: 1, monthDay: day)
        case .yearly:
            return RecurrenceSpec(frequency: .yearly, interval: 1, monthDay: day, months: [month])
        }
    }

    /// spec → 旧档位（仅用于兼容既有筛选/展示字段，不作为真源）
    var legacyType: RecurrenceType {
        switch frequency {
        case .hourly: return .hourly
        case .daily: return interval == 1 ? .daily : .custom
        case .weekly: return interval <= 2 ? .weekly : .custom
        case .monthly: return interval == 1 ? .monthly : .custom
        case .yearly: return interval == 1 ? .yearly : .custom
        }
    }

    // MARK: 预设（严格对齐提醒事项 12 项）

    static func spec(for preset: RecurrencePreset, anchor: Date, current: RecurrenceSpec? = nil) -> RecurrenceSpec? {
        let calendar = Calendar.current
        let day = calendar.component(.day, from: anchor)
        let month = calendar.component(.month, from: anchor)
        switch preset {
        case .never: return nil
        case .hourly: return RecurrenceSpec(frequency: .hourly, interval: 1)
        case .daily: return RecurrenceSpec(frequency: .daily, interval: 1)
        case .workday: return RecurrenceSpec(frequency: .weekly, interval: 1, weekdays: [2, 3, 4, 5, 6])
        case .weekend: return RecurrenceSpec(frequency: .weekly, interval: 1, weekdays: [1, 7])
        case .weekly: return RecurrenceSpec(frequency: .weekly, interval: 1)
        case .biweekly: return RecurrenceSpec(frequency: .weekly, interval: 2)
        case .monthly: return RecurrenceSpec(frequency: .monthly, interval: 1, monthDay: day)
        case .quarterly: return RecurrenceSpec(frequency: .monthly, interval: 3, monthDay: day)
        case .semiannual: return RecurrenceSpec(frequency: .monthly, interval: 6, monthDay: day)
        case .yearly: return RecurrenceSpec(frequency: .yearly, interval: 1, monthDay: day, months: [month])
        case .custom:
            // 进入自定义时保留现有维度，无则从每天起步，避免面板空白
            return current ?? RecurrenceSpec(frequency: .daily, interval: 1)
        }
    }

    /// 反推界面预设（无法归入固定预设即自定义）
    static func preset(for spec: RecurrenceSpec?, anchor: Date) -> RecurrencePreset {
        guard let spec else { return .never }
        let calendar = Calendar.current
        let day = calendar.component(.day, from: anchor)
        let month = calendar.component(.month, from: anchor)
        let anchorWeekday = calendar.component(.weekday, from: anchor)
        switch spec.frequency {
        case .hourly:
            return .hourly
        case .daily:
            return spec.interval == 1 ? .daily : .custom
        case .weekly:
            let days = spec.weekdays
            if spec.interval == 1 {
                if days == [2, 3, 4, 5, 6] { return .workday }
                if days == [1, 7] { return .weekend }
                if days.isEmpty || (days.count == 1 && days[0] == anchorWeekday) { return .weekly }
                return .custom
            }
            if spec.interval == 2, days.isEmpty || (days.count == 1 && days[0] == anchorWeekday) { return .biweekly }
            return .custom
        case .monthly:
            guard spec.nthWeekday == nil, spec.monthDay == day else { return .custom }
            switch spec.interval {
            case 1: return .monthly
            case 3: return .quarterly
            case 6: return .semiannual
            default: return .custom
            }
        case .yearly:
            guard spec.interval == 1, spec.nthWeekday == nil,
                  spec.monthDay == day,
                  spec.months.isEmpty || spec.months == [month] else { return .custom }
            return .yearly
        }
    }

    // MARK: 展示描述

    var displayDescription: String {
        let base: String
        switch frequency {
        case .hourly:
            base = interval == 1 ? "每小时" : "每\(interval)小时"
        case .daily:
            base = interval == 1 ? "每天" : "每\(interval)天"
        case .weekly:
            if interval == 1, weekdays == [2, 3, 4, 5, 6] { base = "工作日" }
            else if interval == 1, weekdays == [1, 7] { base = "周末" }
            else {
                let prefix = interval == 1 ? "每周" : "每\(interval)周"
                base = weekdays.isEmpty ? prefix : prefix + " " + weekdayText
            }
        case .monthly:
            let prefix = interval == 1 ? "每月" : "每\(interval)个月"
            if let nth = nthWeekday { base = "\(prefix) \(nth.displayName)" }
            else if let day = monthDay { base = "\(prefix) \(day)日" }
            else { base = prefix }
        case .yearly:
            let prefix = interval == 1 ? "每年" : "每\(interval)年"
            let monthText = months.first.map { "\($0)月" } ?? ""
            if let nth = nthWeekday { base = "\(prefix) \(monthText)\(nth.displayName)" }
            else if let day = monthDay { base = "\(prefix) \(monthText)\(day)日" }
            else { base = "\(prefix) \(monthText)" }
        }
        switch end.mode {
        case .never: return base
        case .date:
            guard let date = end.date else { return base }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "yyyy-MM-dd"
            return "\(base)，至\(formatter.string(from: date))"
        case .count:
            return "\(base)，共\(end.count ?? 0)次"
        }
    }

    private var weekdayText: String {
        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        return weekdays.sorted { Self.mondayPosition(of: $0) < Self.mondayPosition(of: $1) }.compactMap { w in
            (1...7).contains(w) ? names[w - 1] : nil
        }.joined(separator: "、")
    }
}

// MARK: - 界面预设（截图 12 项）

enum RecurrencePreset: String, CaseIterable, Identifiable {
    case never
    case hourly
    case daily
    case workday
    case weekend
    case weekly
    case biweekly
    case monthly
    case quarterly
    case semiannual
    case yearly
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .never: return "永不"
        case .hourly: return "每小时"
        case .daily: return "每天"
        case .workday: return "工作日"
        case .weekend: return "周末"
        case .weekly: return "每周"
        case .biweekly: return "每两周"
        case .monthly: return "每月"
        case .quarterly: return "每3个月"
        case .semiannual: return "每6个月"
        case .yearly: return "每年"
        case .custom: return "自定义"
        }
    }

    /// 旧档位 → 预设（NLP/存量导入时对齐界面选项）
    static func legacy(_ type: RecurrenceType) -> RecurrencePreset {
        switch type {
        case .none: return .never
        case .hourly: return .hourly
        case .unlimited, .daily: return .daily
        case .weekly: return .weekly
        case .monthly: return .monthly
        case .yearly: return .yearly
        case .custom: return .custom
        }
    }
}

// MARK: - 展开/推进（本地真源）

extension RecurrenceSpec {
    /// 周起点固定周一：EK 在 interval > 1 时同样强制周一起算，本地与系统保持同相位
    static var weekCalendar: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        return calendar
    }

    /// 周一位置：周一=0 ... 周日=6
    static func mondayPosition(of weekday: Int) -> Int {
        (weekday - 2 + 7) % 7
    }

    /// origin 所在周的周一 00:00
    static func weekStart(of date: Date) -> Date {
        let calendar = weekCalendar
        let start = calendar.startOfDay(for: date)
        let offset = mondayPosition(of: calendar.component(.weekday, from: date))
        return calendar.date(byAdding: .day, value: -offset, to: start) ?? start
    }

    /// 第 index 期（index 0 = origin 附近首个合法期）；缺失日期返回 nil（月末/闰日跳过）
    func occurrence(index: Int, origin: Date, isLunar: Bool) -> Date? {
        guard index >= 0 else { return nil }
        if isLunar {
            return Self.lunarOccurrence(index: index, origin: origin, spec: self)
        }
        let calendar = Calendar.current
        let step = max(1, interval)
        switch frequency {
        case .hourly:
            return calendar.date(byAdding: .hour, value: index * step, to: origin)
        case .daily:
            return calendar.date(byAdding: .day, value: index * step, to: origin)
        case .weekly:
            return weeklyOccurrence(index: index, origin: origin)
        case .monthly:
            return monthlyOccurrence(index: index, origin: origin)
        case .yearly:
            return yearlyOccurrence(index: index, origin: origin)
        }
    }

    private func weeklyOccurrence(index: Int, origin: Date) -> Date? {
        let calendar = Self.weekCalendar
        // 按周内实际顺序排序（周日=1 数值最小但在周尾，不能按数值排）
        let days = Array(Set(weekdays)).sorted { Self.mondayPosition(of: $0) < Self.mondayPosition(of: $1) }
        let originStart = calendar.startOfDay(for: origin)
        let timeOfDay = origin.timeIntervalSince(originStart)
        if days.isEmpty {
            return calendar.date(byAdding: .weekOfYear, value: index * max(1, interval), to: origin)
        }
        let originWeekday = calendar.component(.weekday, from: origin)
        let originWeekStart = Self.weekStart(of: origin)
        let validWeek0 = days.filter { Self.mondayPosition(of: $0) >= Self.mondayPosition(of: originWeekday) }
        if index < validWeek0.count {
            return Self.dayDate(weekStart: originWeekStart, weekday: validWeek0[index], timeOfDay: timeOfDay)
        }
        let remaining = index - validWeek0.count
        let block = remaining / days.count
        let position = remaining % days.count
        let weeks = max(1, interval) * (block + 1)
        guard let weekStart = calendar.date(byAdding: .weekOfYear, value: weeks, to: originWeekStart) else { return nil }
        return Self.dayDate(weekStart: weekStart, weekday: days[position], timeOfDay: timeOfDay)
    }

    private static func dayDate(weekStart: Date, weekday: Int, timeOfDay: TimeInterval) -> Date {
        let calendar = weekCalendar
        guard let day = calendar.date(byAdding: .day, value: mondayPosition(of: weekday), to: weekStart) else { return weekStart }
        return day.addingTimeInterval(timeOfDay)
    }

    private func monthlyOccurrence(index: Int, origin: Date) -> Date? {
        let calendar = Calendar.current
        guard let firstOfOriginMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: origin)),
              let targetFirst = calendar.date(byAdding: .month, value: index * max(1, interval), to: firstOfOriginMonth),
              let daysInMonth = calendar.range(of: .day, in: .month, for: targetFirst)?.count else {
            return nil
        }
        var comps = calendar.dateComponents([.year, .month], from: targetFirst)
        if let nth = nthWeekday {
            comps = calendar.dateComponents([.year, .month], from: targetFirst)
            guard let date = Self.nthWeekdayDate(year: comps.year!, month: comps.month!, nth: nth, daysInMonth: daysInMonth, calendar: calendar) else { return nil }
            return Self.applyingTime(of: origin, to: date, calendar: calendar)
        }
        let day = monthDay ?? calendar.component(.day, from: origin)
        guard day <= daysInMonth else { return nil }   // 缺失日期跳过，不回弹
        comps.day = day
        comps.hour = calendar.component(.hour, from: origin)
        comps.minute = calendar.component(.minute, from: origin)
        comps.second = calendar.component(.second, from: origin)
        return calendar.date(from: comps)
    }

    private func yearlyOccurrence(index: Int, origin: Date) -> Date? {
        let calendar = Calendar.current
        let originComps = calendar.dateComponents([.year, .month], from: origin)
        guard let originYear = originComps.year, let originMonth = originComps.month else { return nil }
        let targetYear = originYear + index * max(1, interval)
        let month = months.first ?? originMonth
        guard (1...12).contains(month) else { return nil }
        var comps = DateComponents()
        comps.year = targetYear
        comps.month = month
        comps.day = 1
        guard let firstOfMonth = calendar.date(from: comps),
              let daysInMonth = calendar.range(of: .day, in: .month, for: firstOfMonth)?.count else {
            return nil
        }
        if let nth = nthWeekday {
            guard let date = Self.nthWeekdayDate(year: targetYear, month: month, nth: nth, daysInMonth: daysInMonth, calendar: calendar) else { return nil }
            return Self.applyingTime(of: origin, to: date, calendar: calendar)
        }
        let day = monthDay ?? calendar.component(.day, from: origin)
        guard day <= daysInMonth else { return nil }
        comps.day = day
        comps.hour = calendar.component(.hour, from: origin)
        comps.minute = calendar.component(.minute, from: origin)
        comps.second = calendar.component(.second, from: origin)
        return calendar.date(from: comps)
    }

    private static func nthWeekdayDate(year: Int, month: Int, nth: NthWeekday, daysInMonth: Int, calendar: Calendar) -> Date? {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = 1
        guard let first = calendar.date(from: comps) else { return nil }
        let firstWeekday = calendar.component(.weekday, from: first)
        let target = min(max(nth.weekday, 1), 7)
        let offset = (target - firstWeekday + 7) % 7
        let day: Int
        if nth.nth == -1 {
            // 最后一个目标周几：从月末回退到最近的目标星期
            guard let lastDate = calendar.date(byAdding: .day, value: daysInMonth - 1, to: first) else { return nil }
            let lastWeekday = calendar.component(.weekday, from: lastDate)
            let back = (lastWeekday - target + 7) % 7
            day = daysInMonth - back
        } else {
            day = 1 + offset + (max(nth.nth, 1) - 1) * 7
        }
        guard day >= 1, day <= daysInMonth else { return nil }
        var result = calendar.dateComponents([.year, .month], from: first)
        result.day = day
        return calendar.date(from: result)
    }

    private static func applyingTime(of origin: Date, to date: Date, calendar: Calendar) -> Date {
        let comps = calendar.dateComponents([.hour, .minute, .second], from: origin)
        var dayComps = calendar.dateComponents([.year, .month, .day], from: date)
        dayComps.hour = comps.hour
        dayComps.minute = comps.minute
        dayComps.second = comps.second
        return calendar.date(from: dayComps) ?? date
    }

    /// 首个不早于 origin 的期（多选星期/每月日期早于起始日时顺延）
    func firstOccurrence(from origin: Date, isLunar: Bool) -> Date? {
        for index in 0..<80 {
            guard let candidate = occurrence(index: index, origin: origin, isLunar: isLunar) else { continue }
            if candidate >= origin { return candidate }
        }
        return nil
    }

    /// 与 occurrence 互逆的期序号；monthly/yearly 允许日期漂移（用于历史迁移重定键）
    func index(of date: Date, origin: Date, isLunar: Bool) -> Int? {
        if isLunar {
            let calendar = Calendar(identifier: .chinese)
            let unit: Calendar.Component
            switch frequency {
            case .hourly: unit = .hour
            case .daily: unit = .day
            case .weekly: unit = .weekOfYear
            case .monthly: unit = .month
            case .yearly: unit = .year
            }
            let diff = calendar.dateComponents([unit], from: origin, to: date)
            let raw = diff.value(for: unit) ?? 0
            let idx = raw / max(1, interval)
            return idx >= 0 ? idx : nil
        }
        let calendar = Calendar.current
        switch frequency {
        case .hourly:
            let diff = calendar.dateComponents([.hour], from: origin, to: date).hour ?? 0
            return diff >= 0 ? diff / max(1, interval) : nil
        case .daily:
            let diff = calendar.dateComponents([.day], from: origin, to: date).day ?? 0
            return diff >= 0 ? diff / max(1, interval) : nil
        case .weekly:
            let days = calendar.dateComponents([.day], from: origin, to: date).day ?? 0
            if weekdays.isEmpty {
                guard days >= 0 else { return nil }
                let weeks = Int((Double(days) / 7.0).rounded(.down))
                return weeks / max(1, interval)
            }
            guard days >= 0 else { return nil }
            let daysSorted = Array(Set(weekdays)).sorted { Self.mondayPosition(of: $0) < Self.mondayPosition(of: $1) }
            let originWeekStart = Self.weekStart(of: origin)
            let dateWeekStart = Self.weekStart(of: date)
            let weeks = calendar.dateComponents([.weekOfYear], from: originWeekStart, to: dateWeekStart).weekOfYear ?? 0
            let originWeekday = calendar.component(.weekday, from: origin)
            let dateWeekday = calendar.component(.weekday, from: date)
            let validWeek0 = daysSorted.filter { Self.mondayPosition(of: $0) >= Self.mondayPosition(of: originWeekday) }
            if weeks <= 0 {
                // 起始周内：index 0 = 首个合法星期（多选星期首期顺延的锚点）
                if let pos = validWeek0.firstIndex(of: dateWeekday) { return pos }
                return 0
            }
            // 后续周：第 k 个活动周 = interval*(k+1)，故 block = weeks/interval - 1
            let block = max(0, weeks / max(1, interval) - 1)
            let position = daysSorted.firstIndex(of: dateWeekday) ?? 0
            return validWeek0.count + block * daysSorted.count + position
        case .monthly:
            // 按月历月份差（不能用 .month 差值：1/31→3/28 只算 1 个完整月）
            guard let oy = calendar.dateComponents([.year], from: origin).year,
                  let om = calendar.dateComponents([.month], from: origin).month,
                  let dy = calendar.dateComponents([.year], from: date).year,
                  let dm = calendar.dateComponents([.month], from: date).month else { return nil }
            let diff = (dy - oy) * 12 + (dm - om)
            return diff >= 0 ? diff / max(1, interval) : nil
        case .yearly:
            guard let oy = calendar.dateComponents([.year], from: origin).year,
                  let dy = calendar.dateComponents([.year], from: date).year else { return nil }
            let diff = dy - oy
            return diff >= 0 ? diff / max(1, interval) : nil
        }
    }

    /// 单个步进：严格大于 date 的下一期；受 end（日期/次数）约束
    func next(after date: Date, origin: Date, isLunar: Bool) -> Date? {
        guard let startIndex = index(of: date, origin: origin, isLunar: isLunar) else {
            // 非序列点（旧游标漂移）：从 origin 顺序找第一个晚于 date 的期
            for index in 0..<800 {
                guard let candidate = occurrence(index: index, origin: origin, isLunar: isLunar) else { continue }
                if candidate > date, allows(index: index, origin: origin, isLunar: isLunar) { return candidate }
            }
            return nil
        }
        for index in (startIndex + 1)..<(startIndex + 800) {
            guard allows(index: index, origin: origin, isLunar: isLunar) else { return nil }
            guard let candidate = occurrence(index: index, origin: origin, isLunar: isLunar) else { continue }
            if candidate > date { return candidate }
        }
        return nil
    }

    /// 单个回退：严格小于 date 的上一期
    func previous(before date: Date, origin: Date, isLunar: Bool) -> Date? {
        guard let startIndex = index(of: date, origin: origin, isLunar: isLunar), startIndex > 0 else { return nil }
        for index in stride(from: startIndex - 1, through: 0, by: -1) {
            guard let candidate = occurrence(index: index, origin: origin, isLunar: isLunar) else { continue }
            if candidate < date { return candidate }
        }
        return nil
    }

    /// end 约束：日期端越界或次数端耗尽即终止
    func allows(index: Int, origin: Date, isLunar: Bool) -> Bool {
        switch end.mode {
        case .never:
            return true
        case .date:
            guard let endDate = end.date else { return true }
            guard let occ = occurrence(index: index, origin: origin, isLunar: isLunar) else { return true }
            return occ <= endDate
        case .count:
            return index < max(1, end.count ?? 1)
        }
    }

    /// 窗口起点对齐：直接返回 ≤ windowStart 的最近一期，避免从远古锚点空转
    func alignedOccurrence(before windowStart: Date, origin: Date, isLunar: Bool) -> Date? {
        guard !isLunar else { return nil }
        let calendar = Calendar.current
        let diff: Int
        switch frequency {
        case .hourly: diff = calendar.dateComponents([.hour], from: origin, to: windowStart).hour ?? 0
        case .daily: diff = calendar.dateComponents([.day], from: origin, to: windowStart).day ?? 0
        case .weekly:
            if weekdays.isEmpty {
                diff = (calendar.dateComponents([.day], from: origin, to: windowStart).day ?? 0) / 7
            } else {
                guard let idx = index(of: windowStart, origin: origin, isLunar: false) else { return nil }
                var candidate = idx
                while candidate >= 0 {
                    if let occ = occurrence(index: candidate, origin: origin, isLunar: false), occ <= windowStart { return occ }
                    candidate -= 1
                }
                return nil
            }
        case .monthly: diff = calendar.dateComponents([.month], from: origin, to: windowStart).month ?? 0
        case .yearly: diff = calendar.dateComponents([.year], from: origin, to: windowStart).year ?? 0
        }
        var index = max(0, diff / max(1, interval))
        while index >= 0 {
            if let occ = occurrence(index: index, origin: origin, isLunar: false), occ <= windowStart { return occ }
            index -= 1
            if index < 0 { break }
        }
        return nil
    }

    // MARK: 农历（仅本地）

    private static func lunarOccurrence(index: Int, origin: Date, spec: RecurrenceSpec) -> Date? {
        let calendar = Calendar(identifier: .chinese)
        let step = max(1, spec.interval)
        switch spec.frequency {
        case .hourly: return calendar.date(byAdding: .hour, value: index * step, to: origin)
        case .daily: return calendar.date(byAdding: .day, value: index * step, to: origin)
        case .weekly: return calendar.date(byAdding: .day, value: index * step * 7, to: origin)
        case .monthly: return calendar.date(byAdding: .month, value: index * step, to: origin)
        case .yearly: return calendar.date(byAdding: .year, value: index * step, to: origin)
        }
    }
}

// MARK: - EventKit 正/反向映射（单一入口）

enum RecurrenceEKMapper {
    /// 唯一「仅本地」判定：只有 EK 无法表达的两种情形——
    /// 1) 每小时：EKRecurrenceFrequency 无 hourly；
    /// 2) 农历：相位与公历不同，写公历规则会落错日期。
    /// 自定义（interval/星期/每月日期/第 N 个周几/每年月份/结束条件）均可表达，不在其中。
    static func isLocalOnly(_ spec: RecurrenceSpec, isLunar: Bool) -> Bool {
        isLunar || spec.frequency == .hourly
    }

    /// 本地 spec → EK 规则；仅 isLocalOnly 情形返回 nil（仅本地生效）
    static func rule(for spec: RecurrenceSpec, anchor: Date, isLunar: Bool) -> EKRecurrenceRule? {
        guard !isLocalOnly(spec, isLunar: isLunar) else { return nil }
        let end: EKRecurrenceEnd?
        switch spec.end.mode {
        case .never: end = nil
        case .date: end = spec.end.date.map { EKRecurrenceEnd(end: $0) }
        case .count: end = EKRecurrenceEnd(occurrenceCount: max(1, spec.end.count ?? 1))
        }
        let interval = max(1, spec.interval)
        let weekdayDays: [EKRecurrenceDayOfWeek]?
        let monthDays: [NSNumber]?
        let months: [NSNumber]?
        // 「第 N 个周几」用 BYSETPOS 表达：BYDAY 只给星期（weekNumber 0），
        // 由 setPositions 指定第几个（-1 = 最后一个）；两者同时写 weekNumber 会互相矛盾
        let positions: [NSNumber]?
        switch spec.frequency {
        case .daily:
            weekdayDays = nil; monthDays = nil; months = nil; positions = nil
        case .hourly:
            // 每小时仅本地承载：isLocalOnly guard 已拦截，此处保持穷尽，不得降级为「每天」
            return nil
        case .weekly:
            let days = spec.weekdays.isEmpty
                ? [Calendar.current.component(.weekday, from: anchor)]
                : spec.weekdays
            weekdayDays = uniqueWeekdayNumbers(days).map { EKRecurrenceDayOfWeek(dayOfTheWeek: EKWeekday(rawValue: $0)!, weekNumber: 0) }
            monthDays = nil; months = nil; positions = nil
        case .monthly:
            if let nth = spec.nthWeekday {
                weekdayDays = [EKRecurrenceDayOfWeek(dayOfTheWeek: EKWeekday(rawValue: nth.weekday)!, weekNumber: 0)]
                monthDays = nil
                positions = [NSNumber(value: nth.nth)]
            } else {
                weekdayDays = nil
                monthDays = [NSNumber(value: spec.monthDay ?? Calendar.current.component(.day, from: anchor))]
                positions = nil
            }
            months = nil
        case .yearly:
            let month = spec.months.first ?? Calendar.current.component(.month, from: anchor)
            months = [NSNumber(value: month)]
            if let nth = spec.nthWeekday {
                weekdayDays = [EKRecurrenceDayOfWeek(dayOfTheWeek: EKWeekday(rawValue: nth.weekday)!, weekNumber: 0)]
                monthDays = nil
                positions = [NSNumber(value: nth.nth)]
            } else {
                weekdayDays = nil
                monthDays = [NSNumber(value: spec.monthDay ?? Calendar.current.component(.day, from: anchor))]
                positions = nil
            }
        }
        let frequency: EKRecurrenceFrequency
        switch spec.frequency {
        case .daily: frequency = .daily
        case .weekly: frequency = .weekly
        case .monthly: frequency = .monthly
        case .yearly: frequency = .yearly
        case .hourly:
            // 不可达（上方 guard），保持穷尽：每小时不产生任何系统规则
            return nil
        }
        return EKRecurrenceRule(
            recurrenceWith: frequency,
            interval: interval,
            daysOfTheWeek: weekdayDays,
            daysOfTheMonth: monthDays,
            monthsOfTheYear: months,
            weeksOfTheYear: nil,
            daysOfTheYear: nil,
            setPositions: positions,
            end: end
        )
    }

    /// EK 规则 → 本地 spec；无规则或每小时/农历回落返回 nil
    static func spec(from rule: EKRecurrenceRule?, anchor: Date, inferredType: RecurrenceType) -> RecurrenceSpec? {
        guard let rule else { return nil }
        if inferredType == .hourly {
            // EK 无 hourly：Apple 物化历史推断出的每小时档位仅本地表达
            return RecurrenceSpec(frequency: .hourly, interval: 1)
        }
        let calendar = Calendar.current
        let anchorDay = calendar.component(.day, from: anchor)
        let anchorMonth = calendar.component(.month, from: anchor)
        let end: RecurrenceEndRule
        if let ekEnd = rule.recurrenceEnd {
            if let date = ekEnd.endDate {
                end = .on(date)
            } else if ekEnd.occurrenceCount > 0 {
                end = .after(ekEnd.occurrenceCount)
            } else {
                end = .never
            }
        } else {
            end = .never
        }
        let weekdays = (rule.daysOfTheWeek ?? []).map { Int($0.dayOfTheWeek.rawValue) }.sorted()
        let monthDays = (rule.daysOfTheMonth ?? []).map { $0.intValue }
        let months = (rule.monthsOfTheYear ?? []).map { $0.intValue }.sorted()
        // 第 N 个周几既有 weekNumber 形式，也有 BYDAY + BYSETPOS 形式，两种都要读回，
        // 否则下次同步会把自定义降级成「按日期」
        let nth = nthWeekday(from: rule)
        switch rule.frequency {
        case .daily:
            return RecurrenceSpec(frequency: .daily, interval: rule.interval, end: end)
        case .weekly:
            return RecurrenceSpec(frequency: .weekly, interval: rule.interval, weekdays: weekdays, end: end)
        case .monthly:
            if let nth {
                return RecurrenceSpec(frequency: .monthly, interval: rule.interval, nthWeekday: nth, end: end)
            }
            return RecurrenceSpec(frequency: .monthly, interval: rule.interval, monthDay: monthDays.first ?? anchorDay, end: end)
        case .yearly:
            if let nth {
                return RecurrenceSpec(frequency: .yearly, interval: rule.interval, nthWeekday: nth, months: months.isEmpty ? [anchorMonth] : months, end: end)
            }
            return RecurrenceSpec(frequency: .yearly, interval: rule.interval, monthDay: monthDays.first ?? anchorDay, months: months.isEmpty ? [anchorMonth] : months, end: end)
        @unknown default:
            return nil
        }
    }

    /// 从 EK 规则还原「第 N 个周几」：weekNumber 优先，其次 BYSETPOS
    private static func nthWeekday(from rule: EKRecurrenceRule) -> NthWeekday? {
        guard let dayOfWeek = (rule.daysOfTheWeek ?? []).first else { return nil }
        let position: Int
        if dayOfWeek.weekNumber != 0 {
            position = dayOfWeek.weekNumber
        } else if let first = (rule.setPositions ?? []).first.map({ $0.intValue }), (1...5).contains(abs(first)) {
            position = first
        } else {
            return nil
        }
        return NthWeekday(nth: position, weekday: Int(dayOfWeek.dayOfTheWeek.rawValue))
    }

    private static func uniqueWeekdayNumbers(_ days: [Int]) -> [Int] {
        Array(Set(days.filter { (1...7).contains($0) })).sorted()
    }
}
