//
//  ICSService.swift
//  SwallowCalendar
//

import Foundation

final class ICSService {
    static let shared = ICSService()

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

    // MARK: - Cache Management

    /// 清除磁盘上的 ICS 文件缓存
    func clearCache() {
        // 清除磁盘 ICS 文件缓存
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwallowCalendar/ICS", isDirectory: true)
        try? FileManager.default.removeItem(at: cacheDir)
        print("[ICSService] 订阅日历磁盘缓存已清除")
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
                // 非 UTC 时间，使用本地时区
                formatter.timeZone = TimeZone.current
                formatter.dateFormat = "yyyyMMdd'T'HHmmss"
            }
        } else {
            // 全天事件 - 使用本地时区
            formatter.timeZone = TimeZone.current
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
