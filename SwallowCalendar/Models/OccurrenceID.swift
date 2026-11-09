//
//  OccurrenceID.swift
//  SwallowCalendar
//
//  复合 occurrence ID 的纯工具（无 SwiftData / EventKit 依赖）。
//  抽成独立文件是为了让 LunarMirrorPolicy 等纯函数层可以复用解析，
//  而不被 CachedEvent（@Model）间接带入框架依赖。
//  格式与历史数据完全一致："<baseID>|occ:<epoch>"，不允许变更。
//

import Foundation

enum OccurrenceID {
    /// 复合 ID 格式前缀（`|` 分隔符安全：UUID 恒不含 `|`）
    private static let marker = "|occ:"

    /// 构造复合 ID："<baseID>|occ:<epoch>"
    /// 全项目复合 ID 构造唯一入口，禁止调用方手写拼接
    static func make(baseID: String, occurrence: Date) -> String {
        baseID + marker + String(Int(occurrence.timeIntervalSince1970))
    }

    /// 解析复合 ID；普通 ID（不含标记）返回 nil
    /// 全项目复合 ID 解析唯一入口
    static func parse(_ eventID: String) -> (baseID: String, occurrence: Date)? {
        guard let markerRange = eventID.range(of: marker) else { return nil }
        let baseID = String(eventID[..<markerRange.lowerBound])
        let epochString = String(eventID[markerRange.upperBound...])
        guard !baseID.isEmpty, let epoch = TimeInterval(epochString) else { return nil }
        return (baseID, Date(timeIntervalSince1970: epoch))
    }
}
