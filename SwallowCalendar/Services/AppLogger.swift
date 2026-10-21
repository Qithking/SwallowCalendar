//
//  AppLogger.swift
//  SwallowCalendar
//

import os

/// 统一日志管理，按模块分类
/// N-9：subsystem 与 bundle ID 一致，Console.app 可按 bundle ID 过滤
enum AppLogger {
    private static let subsystem = "Qithking.SwallowCalendar"

    static let cache = Logger(subsystem: subsystem, category: "cache")
    static let sync = Logger(subsystem: subsystem, category: "sync")
    static let ics = Logger(subsystem: subsystem, category: "ics")
    static let reminder = Logger(subsystem: subsystem, category: "reminder")
    static let settings = Logger(subsystem: subsystem, category: "settings")
    static let ui = Logger(subsystem: subsystem, category: "ui")
}
