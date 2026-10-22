//
//  CountdownFormatter.swift
//  SwallowCalendar
//
//  倒计时格式化与临期色阶（从 EventItemRow.CountdownTextView 抽取，文案逐字符不变）
//  提供 AC-1 临期色阶档位：urgent <1h 红 / approaching 1-24h 橙 / normal 保持主题色

import SwiftUI

enum CountdownFormatter {

    /// 临期档位（已过期归 normal，保持现状主题色不参与色阶）
    enum Tier: Equatable {
        case normal       // >= 24h 或已过期
        case approaching  // 1h ~ 24h
        case urgent       // < 1h（未过期）
    }

    /// 剩余秒数 -> 倒计时文案（N年N天/N天/N小时/N分N秒/N秒/已过期）
    static func formatCountdown(remaining: TimeInterval) -> String {
        guard remaining > 0 else { return "已过期" }
        let total = Int(remaining)
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60

        if days >= 365 {
            let years = days / 365
            let remainDays = days % 365
            return remainDays > 0 ? "\(years)年\(remainDays)天" : "\(years)年"
        } else if days >= 1 {
            return "\(days)天"
        } else if hours >= 1 {
            return "\(hours)小时"
        } else if minutes > 0 {
            return "\(minutes)分\(seconds)秒"
        } else {
            return "\(seconds)秒"
        }
    }

    /// 剩余秒数 -> 临期档位
    static func tier(remaining: TimeInterval) -> Tier {
        if remaining <= 0 { return .normal }
        if remaining < 3600 { return .urgent }
        if remaining < 86400 { return .approaching }
        return .normal
    }

    /// 档位 -> 背景色：urgent 红 / approaching 橙（系统语义色暗色自适应）/ normal 用主题色
    static func tierColor(_ tier: Tier, accentHex: String) -> Color {
        switch tier {
        case .urgent: return .red
        case .approaching: return .orange
        case .normal: return Color(hex: accentHex)
        }
    }
}
