//
//  LegacySandboxStoreMigrator.swift
//  SwallowCalendar
//
//  沙盒→非沙盒存储路径切换的一次性订阅源迁移器
//  (fix: subscription-data-lost-after-sandbox-switch)
//
//  根因:entitlements app-sandbox 由 true 改为 false(commit e1dc1b5)后,
//  SwiftData 存储路径从沙盒容器切到 ~/Library/Application Support/default.store,
//  订阅源留在旧容器库且无迁移机制;seed 兜底又被遗留的 hasSeededDefaultCalendarSource
//  = true 标记挡住,默认源不会自动重建 → 升级后订阅数据「消失」。
//

import Foundation
import SwiftData
import SQLite3

enum LegacySandboxStoreMigrator {

    /// 旧库中订阅源的原始字段(状态原样保留)
    struct LegacySource: Equatable {
        let name: String
        let icsURL: String
        let isEnabled: Bool
        let isImportant: Bool
    }

    enum MigrationError: LocalizedError {
        case openFailed(String)
        case queryFailed(String)

        var errorDescription: String? {
            switch self {
            case .openFailed(let detail): return "旧沙盒库打开失败: \(detail)"
            case .queryFailed(let detail): return "旧沙盒库查询失败: \(detail)"
            }
        }
    }

    /// 旧沙盒库路径(沙盒时代 bundle ID 固定为 Qithking.SwallowCalendar,与当前一致)
    static let legacyStoreURL = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask).first!
        .appendingPathComponent(
            "Containers/Qithking.SwallowCalendar/Data/Library/Application Support/default.store"
        )

    // MARK: - 旧库只读抽取

    /// sqlite3 只读直读旧库订阅源。
    /// 不经 SwiftData 打开:旧库 schema 缺 CachedEvent 等新模型,全量 schema 打开会
    /// 触发自动迁移写旧库,与只读恢复意图冲突,故用系统 SQLite C API 直读
    static func fetchLegacySources(at url: URL) throws -> [LegacySource] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, db != nil else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw MigrationError.openFailed(message)
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT ZISENABLED, ZISIMPORTANT, ZICSURL, ZNAME
        FROM ZCUSTOMCALENDARSOURCE ORDER BY Z_PK
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, statement != nil else {
            throw MigrationError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        var sources: [LegacySource] = []
        // 循环内记录退出码：正常耗尽时末次 step 已返回 SQLITE_DONE，
        // 循环结束后再 step 一次会返回 SQLITE_MISUSE（实测），不能用第二次 step 判定
        while true {
            let rc = sqlite3_step(statement)
            if rc != SQLITE_ROW {
                // 循环只认 SQLITE_ROW 为继续；中途 SQLITE_BUSY/CORRUPT 等错误同样退出循环，
                // 静默返回部分源会令调用方迁移一半就落完成标记，剩余订阅永久丢失——
                // 非 SQLITE_DONE 一律抛错，调用方 catch 后不落标记，下次启动重试
                guard rc == SQLITE_DONE else {
                    throw MigrationError.queryFailed(String(cString: sqlite3_errmsg(db)))
                }
                break
            }
            sources.append(LegacySource(
                name: columnText(statement, 3),
                icsURL: columnText(statement, 2),
                isEnabled: sqlite3_column_int(statement, 0) != 0,
                isImportant: sqlite3_column_int(statement, 1) != 0
            ))
        }
        return sources
    }

    /// 安全读文本列(NULL 返回空串);按 column_bytes 定长解码 UTF8,用完即释放
    private static func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let text = sqlite3_column_text(statement, index) else { return "" }
        let byteCount = Int(sqlite3_column_bytes(statement, index))
        return String(
            decoding: UnsafeBufferPointer(start: text, count: byteCount),
            as: UTF8.self
        )
    }

    // MARK: - 迁移执行

    /// 把旧源迁入当前库:同 URL 已存在则跳过(幂等,可重复调用),状态原样保留。
    /// 返回迁移条数;落库 save 由调用方统一执行(与 seed 段落库风格一致)
    @discardableResult
    static func migrateIfNeeded(into context: ModelContext, legacySources: [LegacySource]) -> Int {
        guard !legacySources.isEmpty else { return 0 }
        let existingURLs = Set((try? context.fetch(FetchDescriptor<CustomCalendarSource>()))?.map(\.icsURL) ?? [])
        guard !existingURLs.isEmpty else {
            // Target 无任何源,直接全量迁入
            legacySources.forEach { source in insert(source, into: context) }
            return legacySources.count
        }

        var migrated = 0
        for source in legacySources where !existingURLs.contains(source.icsURL) {
            insert(source, into: context)
            migrated += 1
        }
        return migrated
    }

    private static func insert(_ source: LegacySource, into context: ModelContext) {
        context.insert(CustomCalendarSource(
            name: source.name,
            icsURL: source.icsURL,
            isEnabled: source.isEnabled,
            isImportant: source.isImportant
        ))
    }
}
