//
//  DatabaseMigrator.swift
//  SwallowCalendar
//
//  数据库迁移辅助类，用于处理 SwiftData 模型变更时的数据迁移
//

import Foundation
import SwiftData
import SQLite3

/// 数据库迁移器
struct DatabaseMigrator {
    /// 迁移旧数据库到新 schema
    static func migrateIfNeeded() {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let dbFolder = appSupport.appendingPathComponent("SwallowCalendar")
        let storeFile = dbFolder.appendingPathComponent("Store.sqlite")
        
        // 检查旧数据库是否存在
        guard FileManager.default.fileExists(atPath: storeFile.path) else {
            print("[SwiftData] 没有旧数据库，无需迁移")
            return
        }
        
        print("[SwiftData] 检测到旧数据库，开始迁移...")
        
        // 读取旧数据
        var db: OpaquePointer?
        guard sqlite3_open(storeFile.path, &db) == SQLITE_OK else {
            print("[SwiftData] 无法打开旧数据库，清理后继续")
            cleanupOldDatabase()
            return
        }
        
        // 检查旧表结构是否有 category 列
        let hasCategoryColumn = checkColumnExists(db: db!, table: "CachedEvent", column: "categoryRaw")
        if hasCategoryColumn {
            print("[SwiftData] 数据库已是最新版本，无需迁移")
            sqlite3_close(db)
            return
        }
        
        // 读取旧数据
        var events: [[String: Any]] = []
        var calendars: [[String: Any]] = []
        var sources: [[String: Any]] = []
        
        // 读取 CachedEvent
        events = readCachedEvents(db: db!)
        calendars = readCalendarPreferences(db: db!)
        sources = readCustomCalendarSources(db: db!)
        
        print("[SwiftData] 读取到 \(events.count) 个事件, \(calendars.count) 个日历设置, \(sources.count) 个订阅源")
        
        // 关闭旧数据库
        sqlite3_close(db)
        
        // 没有数据需要迁移，清理旧库
        if events.isEmpty && calendars.isEmpty && sources.isEmpty {
            cleanupOldDatabase()
            print("[SwiftData] 无需迁移数据，已清理旧数据库")
            return
        }
        
        // 删除旧数据库
        cleanupOldDatabase()
        
        // 保存旧数据到临时文件
        let tempData: [String: Any] = [
            "events": events,
            "calendars": calendars,
            "sources": sources
        ]
        
        let tempFile = dbFolder.appendingPathComponent("migration_temp.json")
        if let jsonData = try? JSONSerialization.data(withJSONObject: tempData, options: []) {
            try? jsonData.write(to: tempFile)
            print("[SwiftData] 旧数据已保存到临时文件")
        }
        
        print("[SwiftData] 数据迁移准备完成，新数据库将自动创建并迁移数据")
    }
    
    /// 从临时文件恢复迁移数据到新数据库
    static func restoreMigratedData(to container: ModelContainer) {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let dbFolder = appSupport.appendingPathComponent("SwallowCalendar")
        let tempFile = dbFolder.appendingPathComponent("migration_temp.json")
        
        guard FileManager.default.fileExists(atPath: tempFile.path),
              let jsonData = try? Data(contentsOf: tempFile),
              let tempData = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return
        }
        
        let context = ModelContext(container)
        
        // 恢复 CalendarPreference
        if let calendars = tempData["calendars"] as? [[String: Any]] {
            for pref in calendars {
                if let calendarID = pref["calendarID"] as? String,
                   let isEnabled = pref["isEnabled"] as? Bool {
                    let calendarPref = CalendarPreference(calendarID: calendarID, isEnabled: isEnabled)
                    context.insert(calendarPref)
                }
            }
        }
        
        // 恢复 CustomCalendarSource
        if let sources = tempData["sources"] as? [[String: Any]] {
            for src in sources {
                if let name = src["name"] as? String,
                   let icsURL = src["icsURL"] as? String,
                   let isEnabled = src["isEnabled"] as? Bool {
                    let source = CustomCalendarSource(name: name, icsURL: icsURL, isEnabled: isEnabled)
                    context.insert(source)
                }
            }
        }
        
        // 恢复 CachedEvent（计算 category 字段）
        if let events = tempData["events"] as? [[String: Any]] {
            for event in events {
                guard let eventID = event["eventID"] as? String,
                      let title = event["title"] as? String,
                      let startDate = event["startDate"] as? Double,
                      let endDate = event["endDate"] as? Double,
                      let isAllDay = event["isAllDay"] as? Bool,
                      let calendarID = event["calendarID"] as? String,
                      let calendarTitle = event["calendarTitle"] as? String,
                      let calendarColorHex = event["calendarColorHex"] as? String,
                      let isSubscription = event["isSubscription"] as? Bool else {
                    continue
                }
                
                // 计算 category
                let category: EventCategory = isSubscription ? .subscription : .system
                
                let cached = CachedEvent(
                    eventID: eventID,
                    title: title,
                    startDate: Date(timeIntervalSince1970: startDate),
                    endDate: Date(timeIntervalSince1970: endDate),
                    isAllDay: isAllDay,
                    calendarID: calendarID,
                    calendarTitle: calendarTitle,
                    calendarColorHex: calendarColorHex,
                    category: category
                )
                context.insert(cached)
            }
        }
        
        try? context.save()
        
        // 删除临时文件
        try? FileManager.default.removeItem(at: tempFile)
        print("[SwiftData] 迁移数据已恢复到新数据库")
    }
    
    // MARK: - Private Helpers
    
    private static func cleanupOldDatabase() {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let dbFolder = appSupport.appendingPathComponent("SwallowCalendar")
        
        let storeFile = dbFolder.appendingPathComponent("Store.sqlite")
        let shmFile = dbFolder.appendingPathComponent("Store.sqlite-shm")
        let walFile = dbFolder.appendingPathComponent("Store.sqlite-wal")
        
        try? FileManager.default.removeItem(at: storeFile)
        try? FileManager.default.removeItem(at: shmFile)
        try? FileManager.default.removeItem(at: walFile)
    }
    
    private static func readCachedEvents(db: OpaquePointer) -> [[String: Any]] {
        var events: [[String: Any]] = []
        var stmt: OpaquePointer?
        
        let sql = "SELECT eventID, title, startDate, endDate, isAllDay, calendarID, calendarTitle, calendarColorHex, isSubscription FROM CachedEvent"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return events }
        defer { sqlite3_finalize(stmt) }
        
        while sqlite3_step(stmt) == SQLITE_ROW {
            var event: [String: Any] = [:]
            event["eventID"] = String(cString: sqlite3_column_text(stmt, 0))
            event["title"] = String(cString: sqlite3_column_text(stmt, 1))
            event["startDate"] = sqlite3_column_double(stmt, 2)
            event["endDate"] = sqlite3_column_double(stmt, 3)
            event["isAllDay"] = sqlite3_column_int(stmt, 4) != 0
            event["calendarID"] = String(cString: sqlite3_column_text(stmt, 5))
            event["calendarTitle"] = String(cString: sqlite3_column_text(stmt, 6))
            event["calendarColorHex"] = String(cString: sqlite3_column_text(stmt, 7))
            event["isSubscription"] = sqlite3_column_int(stmt, 8) != 0
            events.append(event)
        }
        return events
    }
    
    private static func readCalendarPreferences(db: OpaquePointer) -> [[String: Any]] {
        var calendars: [[String: Any]] = []
        var stmt: OpaquePointer?
        
        let sql = "SELECT calendarID, isEnabled FROM CalendarPreference"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return calendars }
        defer { sqlite3_finalize(stmt) }
        
        while sqlite3_step(stmt) == SQLITE_ROW {
            var pref: [String: Any] = [:]
            pref["calendarID"] = String(cString: sqlite3_column_text(stmt, 0))
            pref["isEnabled"] = sqlite3_column_int(stmt, 1) != 0
            calendars.append(pref)
        }
        return calendars
    }
    
    private static func readCustomCalendarSources(db: OpaquePointer) -> [[String: Any]] {
        var sources: [[String: Any]] = []
        var stmt: OpaquePointer?
        
        let sql = "SELECT name, icsURL, isEnabled FROM CustomCalendarSource"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return sources }
        defer { sqlite3_finalize(stmt) }
        
        while sqlite3_step(stmt) == SQLITE_ROW {
            var src: [String: Any] = [:]
            src["name"] = String(cString: sqlite3_column_text(stmt, 0))
            src["icsURL"] = String(cString: sqlite3_column_text(stmt, 1))
            src["isEnabled"] = sqlite3_column_int(stmt, 2) != 0
            sources.append(src)
        }
        return sources
    }
    
    private static func checkColumnExists(db: OpaquePointer, table: String, column: String) -> Bool {
        var stmt: OpaquePointer?
        let sql = "PRAGMA table_info(\(table))"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = sqlite3_column_text(stmt, 1), String(cString: name) == column {
                return true
            }
        }
        return false
    }
}
