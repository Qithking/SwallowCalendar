//
//  LegacySandboxMigrationTests.swift
//  SwallowCalendarTests
//
//  沙盒→非沙盒存储路径切换的数据迁移测试(fix: subscription-data-lost-after-sandbox-switch)
//  根因:entitlements app-sandbox true→false 后 SwiftData 存储路径从沙盒容器切到
//  Application Support,订阅源留在旧库且无迁移机制。
//

import XCTest
import SwiftData
import SQLite3
@testable import SwallowCalendar

@MainActor
final class LegacySandboxMigrationTests: XCTestCase {

    private func makeInMemoryContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: CachedEvent.self, CalendarPreference.self, CustomCalendarSource.self,
            configurations: config
        )
    }

    private func sources(in container: ModelContainer) throws -> [CustomCalendarSource] {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<CustomCalendarSource>())
    }

    // MARK: - 迁移逻辑

    /// 空 Target + 旧源 → 全部迁入且启用/重要状态保留
    func testMigrateInsertsLegacySourcesPreservingState() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let legacy = [
            LegacySandboxStoreMigrator.LegacySource(
                name: "中国节假日", icsURL: "https://example.com/holiday.ics",
                isEnabled: true, isImportant: true
            ),
            LegacySandboxStoreMigrator.LegacySource(
                name: "备用源", icsURL: "https://example.com/backup.ics",
                isEnabled: false, isImportant: false
            ),
        ]

        let migrated = LegacySandboxStoreMigrator.migrateIfNeeded(into: context, legacySources: legacy)

        XCTAssertEqual(migrated, 2)
        // 手动 ModelContext 无 autosave:insert 仅入本 context 内存,跨 context fetch
        // 读不到未落库数据——save 后再断言(生产链路由调用方 save,迁移器不负责)
        try context.save()
        let all = try sources(in: container)
        XCTAssertEqual(all.count, 2)
        let holiday = try XCTUnwrap(all.first { $0.icsURL == "https://example.com/holiday.ics" })
        XCTAssertTrue(holiday.isEnabled, "旧库中已启用的源迁移后必须保持启用")
        XCTAssertTrue(holiday.isImportant, "旧库中标重要的源迁移后必须保持重要")
        XCTAssertEqual(holiday.name, "中国节假日")
    }

    /// Target 已有同 URL 源 → 跳过不重复插入(幂等,可重复调用)
    func testMigrateSkipsExistingSameURL() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        context.insert(CustomCalendarSource(
            name: "已有源", icsURL: "https://example.com/holiday.ics",
            isEnabled: false, isImportant: false
        ))

        let legacy = [LegacySandboxStoreMigrator.LegacySource(
            name: "中国节假日", icsURL: "https://example.com/holiday.ics",
            isEnabled: true, isImportant: true
        )]
        XCTAssertEqual(LegacySandboxStoreMigrator.migrateIfNeeded(into: context, legacySources: legacy), 0)
        // 预插的"已有源"同样未落库:save 后跨 context 才能读到 count==1
        try context.save()
        XCTAssertEqual(try sources(in: container).count, 1, "同 URL 已存在不得重复插入")
    }

    /// 空旧源列表 → 迁移 0 条,无副作用
    func testMigrateWithEmptyLegacyList() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        XCTAssertEqual(LegacySandboxStoreMigrator.migrateIfNeeded(into: context, legacySources: []), 0)
        XCTAssertEqual(try sources(in: container).count, 0)
    }

    // MARK: - sqlite 直读旧库

    /// 用 sqlite3 建一个旧沙盒库结构的临时库,验证只读抽取字段完整
    func testFetchLegacySourcesReadsLegacyStore() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-migration-test-\(UUID().uuidString).store")
        Self.makeLegacySchemaStore(at: url) { db in
            // 列序与真实旧库 .schema 一致:ZISENABLED, ZISIMPORTANT, ZICSURL, ZNAME
            sqlite3_exec(
                db,
                "INSERT INTO ZCUSTOMCALENDARSOURCE VALUES (1, 1, 1, 1, 1, 'https://example.com/real.ics', '中国节假日')",
                nil, nil, nil
            )
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let fetched = try LegacySandboxStoreMigrator.fetchLegacySources(at: url)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.icsURL, "https://example.com/real.ics")
        XCTAssertEqual(fetched.first?.name, "中国节假日")
        XCTAssertEqual(fetched.first?.isEnabled, true)
        XCTAssertEqual(fetched.first?.isImportant, true)
    }

    /// 旧库不存在 → 抛错(调用方决定是否落定完成标记)
    func testFetchLegacySourcesThrowsOnMissingStore() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-legacy-\(UUID().uuidString).store")
        XCTAssertThrowsError(try LegacySandboxStoreMigrator.fetchLegacySources(at: url))
    }

    // MARK: - 测试辅助:按真实旧库 .schema 建库

    private static let legacySchemaSQL = """
    CREATE TABLE ZCALENDARPREFERENCE (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER);
    CREATE TABLE ZCUSTOMCALENDARSOURCE ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER,
        ZISENABLED INTEGER, ZISIMPORTANT INTEGER, ZICSURL VARCHAR, ZNAME VARCHAR );
    """

    /// 建旧库表结构后回调 db 句柄(建库方测试用)
    private static func makeLegacySchemaStore(
        at url: URL,
        execSQL: (OpaquePointer?) -> Void
    ) {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return
        }
        defer { sqlite3_close(db) }
        if sqlite3_exec(db, legacySchemaSQL, nil, nil, nil) == SQLITE_OK {
            execSQL(db)
        }
    }
}
