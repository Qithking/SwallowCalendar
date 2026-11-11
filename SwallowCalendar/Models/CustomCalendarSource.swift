//
//  CustomCalendarSource.swift
//  SwallowCalendar
//

import Foundation
import SwiftData

@Model
final class CustomCalendarSource {
    // 默认订阅源固定信息（ContentView seed 与判重共用，避免两处字面量漂移）
    static let defaultSourceName = "重要日历"
    static let defaultSourceURL = "https://yangh9.github.io/ChinaCalendar/cal_holiday.ics"

    var name: String
    var icsURL: String
    var isEnabled: Bool
    var isImportant: Bool = false

    init(name: String, icsURL: String, isEnabled: Bool = false, isImportant: Bool = false) {
        self.name = name
        self.icsURL = icsURL
        self.isEnabled = isEnabled
        self.isImportant = isImportant
    }

    // MARK: - seed 判重与去重（seed-dedupe）

    /// 默认订阅源是否应插入：UserDefaults 标记 + 库级 URL 判重双保险
    /// - Note: 标记可能因 cfprefsd 与磁盘 plist 脱节（沙盒→非沙盒迁移遗留
    ///   双 Preferences 来源）被读为 false，仅靠标记曾造成同 URL 重复 seed
    static func shouldSeedDefaultSource(hasSeededFlag: Bool, existingURLs: [String]) -> Bool {
        guard !hasSeededFlag else { return false }
        return !existingURLs.contains(defaultSourceURL)
    }

    /// 计算同 URL 重复源中应删除的对象：每组保留一条，启用 > 重要 > 先出现者优先
    static func duplicatesToRemove(_ sources: [CustomCalendarSource]) -> [CustomCalendarSource] {
        // 保留优先级：启用(2) > 标重要(1) > 普通(0)
        func priority(_ source: CustomCalendarSource) -> Int {
            (source.isEnabled ? 2 : 0) + (source.isImportant ? 1 : 0)
        }
        var keep: [String: CustomCalendarSource] = [:]
        var toRemove: [CustomCalendarSource] = []
        for source in sources {
            guard let kept = keep[source.icsURL] else {
                keep[source.icsURL] = source
                continue
            }
            // 当前条优先级更高 → 反转保留对象，删掉之前保留的
            if priority(source) > priority(kept) {
                toRemove.append(kept)
                keep[source.icsURL] = source
            } else {
                toRemove.append(source)
            }
        }
        return toRemove
    }
}
