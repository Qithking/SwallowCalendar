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

    /// 剩余秒数 -> 倒计时文案（badge-realtime-countdown 实时格式）
    /// 1天内 "HH:mm:ss"（如 08:56:43）；超1天 "N天HH:mm:ss"（如 29天08:56:43）；
    /// ≥1年 "N年M天HH:mm:ss"；≤0 "已过期"
    static func formatCountdown(remaining: TimeInterval) -> String {
        guard remaining > 0 else { return "已过期" }
        let total = Int(remaining)
        let days = total / 86400
        // 天内余量统一补零为 HH:mm:ss 形态
        let inDay = total % 86400
        let time = String(format: "%02d:%02d:%02d", inDay / 3600, (inDay % 3600) / 60, inDay % 60)

        if days >= 365 {
            let years = days / 365
            let remainDays = days % 365
            return remainDays > 0 ? "\(years)年\(remainDays)天\(time)" : "\(years)年\(time)"
        } else if days >= 1 {
            return "\(days)天\(time)"
        } else {
            return time
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

    /// 跨零边沿判定（countdown-overdue-color-sync）：
    /// wasCountingDown = 本胶囊此前是否处于倒计时中；remaining = 当前剩余秒数。
    /// 仅「倒计时中 → 归零」返回 true（跨过截止线的瞬间），用于触发一次外层刷新：
    /// - onAppear 首算即已过期（wasCountingDown=false 且 remaining<=0）不广播，
    ///   交给外层 isOverdue 快照渲染，避免列表重建风暴
    static func crossedDeadline(wasCountingDown: Bool, remaining: TimeInterval) -> Bool {
        wasCountingDown && remaining <= 0
    }
}
