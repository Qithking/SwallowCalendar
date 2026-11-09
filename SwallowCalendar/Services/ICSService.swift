//
//  ICSService.swift
//  SwallowCalendar
//

import Foundation
import os

// E-12：显式 MainActor 隔离——调用方（EventCacheService/设置视图）均在主线程，
// 网络走 URLSession async 不阻塞；把"约定收敛在主线程"固化为类型系统保证
@MainActor
final class ICSService {
    static let shared = ICSService()

    private init() {}

    /// S-4：订阅响应大小上限 5MB——防止超大响应整体读入内存（内存/磁盘 DoS）
    private static let maxResponseSize = 5 * 1024 * 1024

    /// 缓存最大年龄（体检 P1-#4）：超龄视为未命中走网络刷新，订阅内容滞后
    /// 从「最长 7 天」收敛到 30 分钟；失败时旧数据由差集机制保留
    static let cacheMaxAge: TimeInterval = 30 * 60

    // MARK: - Fetch ICS

    /// 从URL下载ICS内容并解析
    func fetchAndParse(url: String) async throws -> [ICSEvent] {
        guard let url = URL(string: url) else {
            throw ICSError.invalidURL
        }
        // S-4：scheme 白名单仅允许 https，防止 file:// 等协议读取本地文件（自伤读取）
        guard url.scheme?.lowercased() == "https" else {
            throw ICSError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        // E-3：校验 HTTP 状态码——非 2xx（如 404/500 错误页 HTML）直接抛错，
        // 否则错误页会被解析且污染本地 ICS 缓存
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            AppLogger.ics.warning("ICS 请求返回非 2xx 状态码 \(httpResponse.statusCode) url=\(url.absoluteString)")
            throw ICSError.networkError
        }
        // S-4：响应大小超限直接抛错，不进入解析与缓存
        guard data.count <= Self.maxResponseSize else {
            AppLogger.ics.warning("ICS 响应超过大小上限 bytes=\(data.count)")
            throw ICSError.responseTooLarge
        }
        // BUG-02：解码失败不再降级为空串——空串会被解析为零事件并写坏缓存
        guard let content = String(data: data, encoding: .utf8) else {
            AppLogger.ics.warning("ICS 响应 UTF-8 解码失败 url=\(url.absoluteString)")
            throw ICSError.invalidPayload
        }

        // BUG-02：先解析成功再写缓存，避免错误响应覆盖可用缓存
        let events = try parseICS(content)
        cacheICSContent(content, for: url.absoluteString)
        return events
    }

    /// 从缓存加载ICS
    /// - Parameter maxAge: 缓存最大年龄（秒）；nil = 不限龄（既有调用方默认）；
    ///   超龄返回 nil 视为未命中，调用方回退网络。年龄取文件 modificationDate
    ///   （fetchAndParse 写缓存即刷新），无需改缓存格式
    func loadCached(url: String, maxAge: TimeInterval? = nil) -> [ICSEvent]? {
        if let maxAge, !isCacheFresh(for: url, maxAge: maxAge) {
            return nil
        }
        guard let content = loadCachedContent(for: url) else { return nil }
        // BUG-02：缓存内容损坏时返回 nil，让调用方回退网络重新拉取
        guard let events = try? parseICS(content) else {
            AppLogger.ics.warning("ICS 缓存解析失败，回退网络拉取 url=\(url)")
            return nil
        }
        return events
    }

    /// 缓存文件是否在 maxAge 内写入；拿不到 mtime 视为超龄（宁可多联网一次）
    private func isCacheFresh(for url: String, maxAge: TimeInterval) -> Bool {
        let filename = cacheFileName(for: url)
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwallowCalendar/ICS", isDirectory: true)
        let fileURL = cacheDir.appendingPathComponent("\(filename).ics")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let modified = attributes[.modificationDate] as? Date else {
            return false
        }
        return Date().timeIntervalSince(modified) <= maxAge
    }

    // MARK: - Parse ICS

    /// BUG-02：解析失败抛错——非 ICS 内容（如 HTML 错误页/截断响应）不得当作"零事件"
    func parseICS(_ content: String) throws -> [ICSEvent] {
        var events: [ICSEvent] = []
        let lines = content.components(separatedBy: .newlines)

        // BUG-02：结构校验——首个非空行须为 BEGIN:VCALENDAR 且必须闭合 END:VCALENDAR
        // 兼容 UTF-8 BOM 前缀（部分订阅源导出带 BOM，否则合法内容会被误判）
        let trimmedLines = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        let firstLine = trimmedLines.first(where: { !$0.isEmpty })
            .map { $0.hasPrefix("\u{FEFF}") ? String($0.dropFirst()) : $0 }
        guard firstLine == "BEGIN:VCALENDAR",
              trimmedLines.contains("END:VCALENDAR") else {
            throw ICSError.invalidPayload
        }

        // B-20：RFC5545 行折叠——以空格/Tab 开头的行是上一行的续行，长摘要/UID
        // 会被折叠成多行，需先展开（并入上一行，去掉首个续行空白）再逐行解析
        var unfolded: [String] = []
        unfolded.reserveCapacity(lines.count)
        for line in lines {
            if let last = unfolded.last, line.hasPrefix(" ") || line.hasPrefix("\t") {
                unfolded[unfolded.count - 1] = last + line.dropFirst()
            } else {
                unfolded.append(line)
            }
        }

        // DateFormatter 创建成本高（约为 string(from:) 的 50 倍），同一次解析内复用；
        // DateFormatter 非线程安全，仅在本次调用线程内顺序使用
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        var currentEvent: ICSEvent?
        var isReadingEvent = false

        for line in unfolded {
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
                event.summary = Self.unescapeText(String(trimmed.dropFirst(8)))
            } else if trimmed.hasPrefix("DTSTART") {
                event.startDate = parseICSDate(trimmed, formatter: formatter)
                // B-11/B-20：值区取最后一个冒号之后——部分生成器 TZID 参数含冒号
                //（如 Outlook 的 "(UTC+08:00) Beijing"），取 parts[1] 会切到参数区
                //（如 "Shanghai"），无 "T" 被误判为全天
                if let valuePart = trimmed.components(separatedBy: ":").last {
                    event.isAllDay = !valuePart.contains("T")
                }
            } else if trimmed.hasPrefix("DTEND") {
                event.endDate = parseICSDate(trimmed, formatter: formatter)
            } else if trimmed.hasPrefix("UID:") {
                event.uid = Self.unescapeText(String(trimmed.dropFirst(4)))
            }

            currentEvent = event
        }

        return events
    }

    // MARK: - ICS TEXT Unescaping

    /// RFC5545 TEXT 反转义（解析侧唯一入口）：
    /// `\\`→`\`、`\,`→`,`、`\;`→`;`、`\n`/`\N`→换行；
    /// 未知序列（如 `\q`）与末尾孤立 `\` 原样保留，不吞反斜杠。
    /// 仅用于属性值（SUMMARY/UID 等），不得用于 TZID/DTSTART 等带参数的结构值。
    static func unescapeText(_ value: String) -> String {
        // 绝大多数事件无转义，直接返回避免无谓的逐字符重建
        guard value.contains("\\") else { return value }

        var result = ""
        result.reserveCapacity(value.count)
        var index = value.startIndex
        while index < value.endIndex {
            let character = value[index]
            guard character == "\\" else {
                result.append(character)
                index = value.index(after: index)
                continue
            }

            let next = value.index(after: index)
            guard next < value.endIndex else {
                // 末尾孤立反斜杠：保留
                result.append("\\")
                break
            }

            switch value[next] {
            case "n", "N": result.append("\n")
            case "\\": result.append("\\")
            case ",": result.append(",")
            case ";": result.append(";")
            default:
                // 未知转义：保留反斜杠与后续字符
                result.append("\\")
                result.append(value[next])
            }
            index = value.index(after: next)
        }
        return result
    }

    // MARK: - Cache Management

    /// 清除磁盘上的 ICS 文件缓存
    func clearCache() {
        // 清除磁盘 ICS 文件缓存
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwallowCalendar/ICS", isDirectory: true)
        try? FileManager.default.removeItem(at: cacheDir)
        AppLogger.ics.info("订阅日历磁盘缓存已清除")
    }

    /// V-38：删除指定订阅源的磁盘缓存文件——重新启用源时调用，
    /// 强制下次同步跳过 loadCached 直接走网络重拉
    func removeCachedFile(for url: String) {
        let filename = cacheFileName(for: url)
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwallowCalendar/ICS", isDirectory: true)
        try? FileManager.default.removeItem(at: cacheDir.appendingPathComponent("\(filename).ics"))
    }
    
    /// 清理过期的缓存文件（超过7天）
    func cleanupExpiredCache() {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwallowCalendar/ICS", isDirectory: true)
        
        guard let files = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.contentModificationDateKey], options: []) else {
            return
        }
        
        let sevenDaysAgo = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        var cleanedCount = 0
        
        for fileURL in files {
            guard let attributes = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modificationDate = attributes.contentModificationDate,
                  modificationDate < sevenDaysAgo else {
                continue
            }
            
            try? FileManager.default.removeItem(at: fileURL)
            cleanedCount += 1
        }
        
        if cleanedCount > 0 {
            AppLogger.ics.info("清理了 \(cleanedCount) 个过期的 ICS 缓存文件")
        }
    }

    // MARK: - ICS Date Parsing

    /// - Parameter formatter: 由调用方创建并复用的格式化器（避免每行新建）
    private func parseICSDate(_ line: String, formatter: DateFormatter) -> Date? {
        // 格式: DTSTART;VALUE=DATE:20260101 或 DTSTART;TZID=Asia/Shanghai:20260101T080000
        // B-20：值区取最后一个冒号之后——TZID 参数可能含冒号，原 parts[1]
        // 会切到参数区导致解析失败
        let parts = line.components(separatedBy: ":")
        guard parts.count >= 2, let rawDate = parts.last else { return nil }
        let dateStr = rawDate.trimmingCharacters(in: .whitespacesAndNewlines)

        // B-20：从参数区（最后一个冒号之前）提取 TZID 时区，无效标识回退本地——
        // 原实现忽略 TZID，非本地时区的订阅日程时间整体偏移
        var timeZone = TimeZone.current
        let paramPart = parts.dropLast().joined(separator: ":")
        if let tzRange = paramPart.range(of: "TZID=") {
            let tzID = String(paramPart[tzRange.upperBound...].prefix { $0 != ";" })
            if let tz = TimeZone(identifier: tzID) {
                timeZone = tz
            }
        }

        // 判断是全天事件还是有时间的事件
        if dateStr.contains("T") {
            // 有时间的事件
            if dateStr.hasSuffix("Z") {
                formatter.timeZone = TimeZone(identifier: "UTC")
                formatter.dateFormat = "yyyyMMdd'T'HHmmss"
                return formatter.date(from: String(dateStr.dropLast()))
            }
            // 非 UTC 时间，优先 TZID 指定时区
            formatter.timeZone = timeZone
            formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        } else {
            // 全天事件 - 使用本地时区
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = "yyyyMMdd"
        }

        return formatter.date(from: dateStr)
    }

    // MARK: - File Cache

    /// S-11：由订阅 URL 派生缓存文件名——base64 编码并替换 "/"（base64 字符集
    /// A-Za-z0-9+/ 中仅 "/" 非法，无路径穿越风险）；空 URL 回退 "default"，
    /// 防止生成隐藏文件 ".ics"
    private func cacheFileName(for url: String) -> String {
        guard let data = url.data(using: .utf8), !data.isEmpty else {
            return "default"
        }
        return data.base64EncodedString().replacingOccurrences(of: "/", with: "_")
    }

    private func cacheICSContent(_ content: String, for url: String) {
        let filename = cacheFileName(for: url)
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwallowCalendar/ICS", isDirectory: true)

        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let fileURL = cacheDir.appendingPathComponent("\(filename).ics")
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
        // S-5：缓存含订阅源事件内容（标题/日期），收紧为仅当前用户可读写
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func loadCachedContent(for url: String) -> String? {
        let filename = cacheFileName(for: url)
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
    /// B-11：是否全天事件——DTSTART 值不含 "T" 即全天（与 parseICSDate 判定一致），
    /// 带时间事件此前被硬编码为全天，导致不参与倒计时
    var isAllDay: Bool = true
}

enum ICSError: LocalizedError {
    case invalidURL
    case networkError
    case parseError
    /// S-4：订阅响应超过大小上限
    case responseTooLarge
    /// BUG-02：订阅内容不是合法 ICS（解码失败/非 VCALENDAR 结构）
    case invalidPayload

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "无效的ICS URL"
        case .networkError: return "网络错误"
        case .parseError: return "ICS解析错误"
        case .responseTooLarge: return "订阅内容超过大小限制（5MB）"
        case .invalidPayload: return "订阅内容不是合法的 ICS 格式"
        }
    }
}
