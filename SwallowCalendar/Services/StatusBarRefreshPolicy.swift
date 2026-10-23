//
//  StatusBarRefreshPolicy.swift
//  SwallowCalendar
//
//  菜单栏图标刷新间隔策略（badge-realtime-countdown B3）
//  抽为纯函数便于直编与单元验证；StatusBarIconManager.refreshInterval 调用
//

import Foundation

enum StatusBarRefreshPolicy {
    /// 计算菜单栏图标刷新间隔（秒）
    /// - Parameters:
    ///   - iconStyle: 当前菜单栏图标样式
    ///   - customFormat: 自定义格式字符串（仅 iconStyle == .customFormat 时参与）
    ///   - badgeEnabled: 倒计时徽标是否开启
    static func computeRefreshInterval(iconStyle: IconStyle, customFormat: String, badgeEnabled: Bool) -> TimeInterval {
        let base: TimeInterval
        switch iconStyle {
        case .calendarIcon:
            base = 0
        case .solidDate, .strokeDate:
            base = 60
        case .customFormat:
            if customFormat.contains("s") {
                base = 1
            } else {
                // mm/HH 及纯日期格式均为分钟级精度，60 秒刷新即可
                base = 60
            }
        }
        // 徽标开启：固定 1s——徽标展示实时倒计时（HH:mm:ss 秒级变化），任何 base 均不适用
        guard badgeEnabled else { return base }
        return 1
    }
}
