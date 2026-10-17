//
//  AppLogger.swift
//  SwallowCalendar
//

import os

/// 统一日志管理，按模块分类
enum AppLogger {
    static let cache = Logger(subsystem: "com.swallowcalendar", category: "cache")
    static let sync = Logger(subsystem: "com.swallowcalendar", category: "sync")
    static let ics = Logger(subsystem: "com.swallowcalendar", category: "ics")
    static let reminder = Logger(subsystem: "com.swallowcalendar", category: "reminder")
    static let settings = Logger(subsystem: "com.swallowcalendar", category: "settings")
    static let ui = Logger(subsystem: "com.swallowcalendar", category: "ui")
}
