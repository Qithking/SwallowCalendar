//
//  ICSServiceValidationTests.swift
//  SwallowCalendarTests
//
//  BUG-02 回归：空/非法 ICS 解析不得被当作"零事件"清空订阅缓存

import XCTest
import SwiftData
@testable import SwallowCalendar

@MainActor
final class ICSServiceValidationTests: XCTestCase {

    // MARK: - 解析结构校验

    /// 触发条件本身：订阅源返回 HTML 错误页（首行不是 BEGIN:VCALENDAR）
    func testHTMLResponseThrowsInvalidPayload() {
        let html = "<!DOCTYPE html><html><head><title>404</title></head><body>Not Found</body></html>"
        XCTAssertThrowsError(try ICSService.shared.parseICS(html)) { error in
            XCTAssertEqual((error as? ICSError)?.errorDescription, ICSError.invalidPayload.errorDescription)
        }
    }

    /// 触发条件本身：合法开头但响应被截断，缺少 END:VCALENDAR
    func testTruncatedICSThrowsInvalidPayload() {
        let truncated = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VEVENT
        SUMMARY:被截断的事件
        """
        XCTAssertThrowsError(try ICSService.shared.parseICS(truncated)) { error in
            XCTAssertEqual((error as? ICSError)?.errorDescription, ICSError.invalidPayload.errorDescription)
        }
    }

    /// 合法空 VCALENDAR：允许解析为 0 事件（是否保留旧行由同步层判定）
    func testEmptyValidCalendarReturnsNoEvents() throws {
        let content = """
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//Test//EN
        END:VCALENDAR
        """
        XCTAssertEqual(try ICSService.shared.parseICS(content).count, 0)
    }

    /// 带 UTF-8 BOM 与 CRLF 换行的合法内容不应被结构校验误杀
    func testBOMContentAccepted() throws {
        let content = "\u{FEFF}BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nSUMMARY:带BOM\r\nUID:bom-1\r\nEND:VEVENT\r\nEND:VCALENDAR"
        let events = try ICSService.shared.parseICS(content)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.uid, "bom-1")
    }

    // MARK: - 缓存损坏回退

    /// 触发条件：缓存文件内容损坏（HTML）→ loadCached 返回 nil，调用方回退联网
    func testLoadCachedReturnsNilForCorruptCache() throws {
        let url = "https://example.com/corrupt-\(UUID().uuidString).ics"
        try seedCache("<html>not an ics</html>", for: url)
        defer { removeCache(for: url) }

        XCTAssertNil(ICSService.shared.loadCached(url: url), "损坏缓存必须返回 nil 而不是零事件")
    }

    /// 合法空缓存仍应返回空数组（与损坏缓存区分）
    func testLoadCachedReturnsEmptyForValidEmptyCalendar() throws {
        let url = "https://example.com/empty-\(UUID().uuidString).ics"
        try seedCache("BEGIN:VCALENDAR\nVERSION:2.0\nEND:VCALENDAR", for: url)
        defer { removeCache(for: url) }

        XCTAssertEqual(ICSService.shared.loadCached(url: url)?.count, 0)
    }

    // MARK: - 同步层保留旧行

    /// 触发条件：源抓取成功但 0 事件，且缓存已有该源的行 → 行必须保留
    func testSyncKeepsRowsWhenSourceReturnsEmptyCalendar() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: CachedEvent.self, configurations: config)
        EventCacheService.shared.configure(with: container)

        let url = "https://example.com/empty-sync-\(UUID().uuidString).ics"
        try seedCache("BEGIN:VCALENDAR\nVERSION:2.0\nEND:VCALENDAR", for: url)
        defer { removeCache(for: url) }

        let context = container.mainContext
        let existing = CachedEvent(
            eventID: "ics-\(url)-uid-1",
            title: "已缓存订阅事件",
            startDate: Date(),
            endDate: Date(),
            isAllDay: false,
            calendarID: url,
            calendarTitle: "测试订阅",
            calendarColorHex: "#FF9500",
            category: .subscription
        )
        context.insert(existing)
        try context.save()

        let source = CustomCalendarSource(name: "测试订阅", icsURL: url, isEnabled: true)
        await EventCacheService.shared.syncSubscriptionEvents(sources: [source])

        let rows = try context.fetch(FetchDescriptor<CachedEvent>())
        XCTAssertEqual(rows.count, 1, "空解析不得差集删除该源已有缓存行")
        XCTAssertEqual(rows.first?.eventID, existing.eventID)
    }

    /// 反向对照：源返回非空合法 ICS 时，差集删除仍正常（改动未削弱常规清理）
    func testSyncStillDeletesStaleRowsWhenSourceReturnsEvents() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: CachedEvent.self, configurations: config)
        EventCacheService.shared.configure(with: container)

        let url = "https://example.com/nonempty-sync-\(UUID().uuidString).ics"
        let content = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VEVENT
        SUMMARY:新事件
        UID:new-1
        DTSTART:20261201T090000
        END:VEVENT
        END:VCALENDAR
        """
        try seedCache(content, for: url)
        defer { removeCache(for: url) }

        let context = container.mainContext
        let stale = CachedEvent(
            eventID: "ics-\(url)-uid-old",
            title: "已移除的旧事件",
            startDate: Date(),
            endDate: Date(),
            isAllDay: false,
            calendarID: url,
            calendarTitle: "测试订阅",
            calendarColorHex: "#FF9500",
            category: .subscription
        )
        context.insert(stale)
        try context.save()

        let source = CustomCalendarSource(name: "测试订阅", icsURL: url, isEnabled: true)
        await EventCacheService.shared.syncSubscriptionEvents(sources: [source])

        let rows = try context.fetch(FetchDescriptor<CachedEvent>())
        XCTAssertFalse(rows.contains { $0.eventID == stale.eventID }, "源中已不存在的旧行应被删除")
    }

    // MARK: - 缓存文件辅助（与 ICSService.cacheFileName 同规则）

    private func cacheFileURL(for url: String) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwallowCalendar/ICS", isDirectory: true)
        let filename = Data(url.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
        return dir.appendingPathComponent("\(filename).ics")
    }

    private func seedCache(_ content: String, for url: String) throws {
        let fileURL = cacheFileURL(for: url)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func removeCache(for url: String) {
        try? FileManager.default.removeItem(at: cacheFileURL(for: url))
    }
}
