//
//  AppLogger.swift
//  SwallowCalendar
//

import os
import Foundation

/// 统一日志管理，按模块分类
/// subsystem 与 bundle ID 一致，Console.app 可按 bundle ID 过滤
enum AppLogger {
    private static let subsystem = "Qithking.SwallowCalendar"

    static let cache = Logger(subsystem: subsystem, category: "cache")
    static let sync = Logger(subsystem: subsystem, category: "sync")
    static let ics = Logger(subsystem: subsystem, category: "ics")
    static let reminder = Logger(subsystem: subsystem, category: "reminder")
    static let settings = Logger(subsystem: subsystem, category: "settings")
    static let ui = Logger(subsystem: subsystem, category: "ui")

    /// 月历取数取证专用独立 subsystem（与业务日志隔离，便于单独抓取）：
    /// log stream --predicate 'subsystem == "Qithking.SwallowCalendar.diag"' --style compact
    static let monthQuery = Logger(subsystem: "Qithking.SwallowCalendar.diag", category: "monthquery")

    /// 取证开关：仅 SC_MONTH_DIAG=1 时输出月历诊断日志，避免常驻刷屏
    static let monthDiagEnabled = ProcessInfo.processInfo.environment["SC_MONTH_DIAG"] == "1"

    /// 月历取证日志入口（关闭时零开销）
    static func monthDiag(_ message: @autoclosure () -> String) {
        guard monthDiagEnabled else { return }
        let text = message()
        monthQuery.notice("\(text, privacy: .public)")
    }
}
