//
//  ICSService.swift
//  SwallowCalendar
//

import Foundation

@Observable
final class ICSService {
    static let shared = ICSService()

    /// 缓存：日期 -> [(来源URL, 事件名称)]
    private var subscriptionCache: [String: [(sourceURL: String, eventName: String)]] = [:]
    private var lastFetchDate: Date?
    
    /// 缓存保留天数
    private let cacheRetentionDays = 90

    private init() {}

    // MARK: - Fetch ICS

    /// 从URL下载ICS内容并解析
    func fetchAndParse(url: String) async throws -> [ICSEvent] {
        guard let url = URL(string: url) else {
            throw ICSError.invalidURL
        }

        let (data, _) = try await URLSession.shared.data(from: url)
        let content = String(data: data, encoding: .utf8) ?? ""

        // 缓存到本地
        cacheICSContent(content, for: url.absoluteString)

        return parseICS(content)
    }

    /// 从缓存加载ICS
    func loadCached(url: String) -> [ICSEvent]? {
        guard let content = loadCachedContent(for: url) else { return nil }
        return parseICS(content)
    }

    // MARK: - Parse ICS

    func parseICS(_ content: String) -> [ICSEvent] {
        var events: [ICSEvent] = []
        let lines = content.components(separatedBy: .newlines)

        var currentEvent: ICSEvent?
        var isReadingEvent = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed == "BEGIN:VEVENT" {
                currentEvent = ICSEvent()
                isReadingEvent = true
                continue
            }

            if trimmed == "END:VEVENT" {
                if let event = currentEvent {
                    events.append(event)
                }
                currentEvent = nil
                isReadingEvent = false
                continue
            }

            guard isReadingEvent, var event = currentEvent else { continue }

            if trimmed.hasPrefix("SUMMARY:") {
                event.summary = String(trimmed.dropFirst(8))
            } else if trimmed.hasPrefix("DTSTART") {
                event.startDate = parseICSDate(trimmed)
            } else if trimmed.hasPrefix("DTEND") {
                event.endDate = parseICSDate(trimmed)
            } else if trimmed.hasPrefix("UID:") {
                event.uid = String(trimmed.dropFirst(4))
            }

            currentEvent = event
        }

        return events
    }

    // MARK: - Subscription Lookup

    /// 获取某天的订阅日历事件
    func subscriptionEvents(for date: Date, sources: [CustomCalendarSource]) async -> [String] {
        // 定期清理过期缓存
        cleanupExpiredCache()
        
        let dateKey = formatDateKey(date)

        // 如果缓存有效且来源未变，直接返回
        if let cached = subscriptionCache[dateKey], !cached.isEmpty {
            return cached.map { $0.eventName }
        }

        var subscriptions: [(sourceURL: String, eventName: String)] = []

        for source in sources where source.isEnabled {
            let events: [ICSEvent]
            if let cached = loadCached(url: source.icsURL) {
                events = cached
            } else {
                do {
                    events = try await fetchAndParse(url: source.icsURL)
                } catch {
                    continue
                }
            }

            for event in events {
                if let eventStart = event.startDate {
                    let eventKey = formatDateKey(eventStart)
                    if eventKey == dateKey {
                        subscriptions.append((sourceURL: source.icsURL, eventName: event.summary))
                    }
                }
            }
        }

        subscriptionCache[dateKey] = subscriptions
        return subscriptions.map { $0.eventName }
    }

    /// 同步版本：基于已缓存数据查询，根据启用的源过滤
    func subscriptionEventsSync(for date: Date, sources: [CustomCalendarSource]) -> [String] {
        let dateKey = formatDateKey(date)
        let allEvents = subscriptionCache[dateKey] ?? []
        // 只返回启用的日历源的事件
        let enabledSourceURLs = Set(sources.filter { $0.isEnabled }.map { $0.icsURL })
        let filtered = allEvents.filter { enabledSourceURLs.contains($0.sourceURL) }
        return filtered.map { $0.eventName }
    }

    /// 预加载订阅日历数据
    func preloadSubscriptions(sources: [CustomCalendarSource]) async {
        // 清理过期缓存
        cleanupExpiredCache()
        
        // 先清除禁用源的缓存数据
        let enabledSourceURLs = Set(sources.filter { $0.isEnabled }.map { $0.icsURL })
        for (key, events) in subscriptionCache {
            let filtered = events.filter { enabledSourceURLs.contains($0.sourceURL) }
            if filtered.isEmpty {
                subscriptionCache.removeValue(forKey: key)
            } else {
                subscriptionCache[key] = filtered
            }
        }

        // 加载启用的源
        for source in sources where source.isEnabled {
            let events: [ICSEvent]
            if let cached = loadCached(url: source.icsURL) {
                events = cached
            } else {
                do {
                    events = try await fetchAndParse(url: source.icsURL)
                } catch {
                    continue
                }
            }

            for event in events {
                if let start = event.startDate {
                    let key = formatDateKey(start)
                    // 避免重复添加
                    let existing = subscriptionCache[key, default: []]
                    if !existing.contains(where: { $0.sourceURL == source.icsURL && $0.eventName == event.summary }) {
                        subscriptionCache[key, default: []].append((sourceURL: source.icsURL, eventName: event.summary))
                    }
                }
            }
        }
        EventCacheService.shared.lastSyncTime = Date()
        print("[ICSService] 预加载完成, 缓存条目数: \(subscriptionCache.count)")
    }

    /// 清除所有订阅日历缓存（内存 + 磁盘）
    func clearCache() {
        subscriptionCache.removeAll()
        // 清除磁盘 ICS 文件缓存
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwallowCalendar/ICS", isDirectory: true)
        try? FileManager.default.removeItem(at: cacheDir)
        print("[ICSService] 订阅日历缓存已清除（内存 + 磁盘）")
    }
    
    /// 清理过期的缓存条目（只保留最近 cacheRetentionDays 天）
    private func cleanupExpiredCache() {
        let calendar = Calendar.current
        let cutoffDate = calendar.date(byAdding: .day, value: -cacheRetentionDays, to: Date())!
        let cutoffKey = formatDateKey(cutoffDate)
        
        let keysToRemove = subscriptionCache.keys.filter { $0 < cutoffKey }
        for key in keysToRemove {
            subscriptionCache.removeValue(forKey: key)
        }
        
        if !keysToRemove.isEmpty {
            print("[ICSService] 清理了 \(keysToRemove.count) 个过期缓存条目")
        }
    }

    // MARK: - ICS Date Parsing

    private func parseICSDate(_ line: String) -> Date? {
        // 格式: DTSTART;VALUE=DATE:20260101 或 DTSTART:20260101T080000Z
        let parts = line.components(separatedBy: ":")
        guard parts.count >= 2 else { return nil }
        var dateStr = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        // 判断是全天事件还是有时间的事件
        if dateStr.contains("T") {
            // 有时间的事件
            if dateStr.hasSuffix("Z") {
                dateStr = String(dateStr.dropLast())
                formatter.timeZone = TimeZone(identifier: "UTC")
                formatter.dateFormat = "yyyyMMdd'T'HHmmss"
            } else {
                formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
                formatter.dateFormat = "yyyyMMdd'T'HHmmss"
            }
        } else {
            // 全天事件 - 使用本地时区的日期
            formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
            formatter.dateFormat = "yyyyMMdd"
        }

        return formatter.date(from: dateStr)
    }

    private func formatDateKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    // MARK: - File Cache

    private func cacheICSContent(_ content: String, for url: String) {
        let filename: String
        if let data = url.data(using: .utf8) {
            filename = data.base64EncodedString().replacingOccurrences(of: "/", with: "_")
        } else {
            filename = "default"
        }
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwallowCalendar/ICS", isDirectory: true)

        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let fileURL = cacheDir.appendingPathComponent("\(filename).ics")
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func loadCachedContent(for url: String) -> String? {
        let filename: String
        if let data = url.data(using: .utf8) {
            filename = data.base64EncodedString().replacingOccurrences(of: "/", with: "_")
        } else {
            filename = "default"
        }
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwallowCalendar/ICS", isDirectory: true)
        let fileURL = cacheDir.appendingPathComponent("\(filename).ics")
        return try? String(contentsOf: fileURL, encoding: .utf8)
    }
}

// MARK: - Models

struct ICSEvent {
    var uid: String = ""
    var summary: String = ""
    var startDate: Date?
    var endDate: Date?
}

enum ICSError: LocalizedError {
    case invalidURL
    case networkError
    case parseError

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "无效的ICS URL"
        case .networkError: return "网络错误"
        case .parseError: return "ICS解析错误"
        }
    }
}
