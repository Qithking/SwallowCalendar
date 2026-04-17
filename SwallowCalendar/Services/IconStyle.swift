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
}
