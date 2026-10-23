//
//  IconStyle.swift
//  SwallowCalendar
//

import Foundation

enum IconStyle: String, CaseIterable, Codable {
    case solidDate = "solidDate"         // 实心日期
    case strokeDate = "strokeDate"       // 描边日期
    case calendarIcon = "calendarIcon"   // 日历图标
    case customFormat = "customFormat"   // 自定义格式

    var displayName: String {
        switch self {
        case .solidDate: return "实心日期"
        case .strokeDate: return "描边日期"
        case .calendarIcon: return "日历图标"
        case .customFormat: return "自定义格式"
        }
    }

    /// D2b：倒计时徽标外观与「菜单栏图标」样式逐项配合——
    /// 实心日期→徽标实心背景、描边日期→徽标描边、日历图标→无背景纯文字，
    /// 自定义格式→沿用专属的「自定义图标样式」子选项
    func badgeStyle(customFormatStyle: AppSettings.CustomFormatStyle) -> AppSettings.CustomFormatStyle {
        switch self {
        case .solidDate: return .solid
        case .strokeDate: return .stroke
        case .calendarIcon: return .none
        case .customFormat: return customFormatStyle
        }
    }
}
