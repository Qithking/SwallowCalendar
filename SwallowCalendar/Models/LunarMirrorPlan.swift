//
//  LunarMirrorPlan.swift
//  SwallowCalendar
//
//  兼容转发层：镜像判定逻辑已收敛到 LunarMirrorPolicy（单一判定源）。
//  本文件仅保留：
//  - notes 标记 / 指纹解析（镜像识别格式，不属于生命周期判定）；
//  - 旧入口的同名转发，保证调用点与历史用例不改动（S3 后删除判定类旧入口）。
//
//  口径见 .work/执行文档.md「农历重复镜像写入方案」：
//  - 每条期次写一条普通公历提醒（不循环），系统侧显示公历；
//  - 闰月正常多出一期，不跳过；
//  - 期次推进与索引统一复用 RecurrenceSpec.occurrence/index(of:)/allows，
//    与应用内农历展开同一套，禁止镜像侧另写日期推进；
//  - 30 日遇 29 天月由系统 Chinese Calendar 落到廿九（不跳过）。
//

import Foundation
import os

enum LunarMirrorPlan {
    // MARK: - notes 标记（镜像识别唯一入口）

    /// 镜像提醒 notes 标记前缀；完整标记 = 前缀 + 复合 occurrence ID
    static let markerPrefix = "[SC_LUNAR_MIRROR]"
    /// 内容指纹段前缀（位于复合 ID 之后的空格分隔段，避免污染 ID 解析）
    static let fingerprintPrefix = "[SC_MIRROR_FP:"

    /// 构造镜像标记（复合 ID 复用 OccurrenceID.make，禁止手写拼接）
    /// - Parameter fingerprint: 内容指纹；为空时退化为「仅 ID」的旧格式（兼容历史镜像）
    static func marker(occurrenceID: String, fingerprint: String? = nil) -> String {
        let marker = markerPrefix + occurrenceID
        guard let fingerprint, !fingerprint.isEmpty else { return marker }
        return "\(marker) \(fingerprintPrefix)\(fingerprint)]"
    }

    /// 从 notes 解析镜像复合 ID；非镜像返回 nil
    static func occurrenceID(from notes: String?) -> String? {
        guard let notes, let range = notes.range(of: markerPrefix) else { return nil }
        let id = notes[range.upperBound...].prefix { !$0.isWhitespace }
        return id.isEmpty ? nil : String(id)
    }

    /// 从 notes 解析内容指纹；旧镜像（无该段）返回 nil
    static func contentFingerprint(from notes: String?) -> String? {
        guard let notes, let range = notes.range(of: fingerprintPrefix) else { return nil }
        guard let end = notes[range.upperBound...].firstIndex(of: "]") else { return nil }
        let fingerprint = notes[range.upperBound..<end]
        return fingerprint.isEmpty ? nil : String(fingerprint)
    }

    /// 稳定哈希（FNV-1a 64）：不能用 String.hashValue（进程内随机种子，跨启动会误判漂移）
    static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    // MARK: - 转发到 LunarMirrorPolicy

    static var windowMonths: Int { LunarMirrorPolicy.windowMonths }
    static var topUpMonths: Int { LunarMirrorPolicy.topUpMonths }

    static func horizon(now: Date, furthestMirror: Date?, calendar: Calendar = .current) -> Date {
        LunarMirrorPolicy.horizon(now: now, furthestMirror: furthestMirror, calendar: calendar)
    }

    static func occurrences(
        spec: RecurrenceSpec,
        origin: Date,
        after lowerBound: Date,
        through upperBound: Date
    ) -> [LunarMirrorOccurrence] {
        LunarMirrorPolicy.occurrences(
            spec: spec,
            origin: origin,
            after: lowerBound,
            through: upperBound
        )
    }

    static func reconcile(
        baseID: String,
        currentDate: Date?,
        origin: Date,
        spec: RecurrenceSpec?,
        isLunar: Bool,
        validStart: Date?,
        validEnd: Date?,
        completedDates: [Date],
        now: Date,
        existing: [ExistingLunarMirror],
        knownKeys: [String] = [],
        suppressedKeys: [String] = [],
        expectedFingerprint: String? = nil,
        skipHolidays: Bool = false,
        isRestDay: ((Date) -> Bool)? = nil,
        calendar: Calendar = .current
    ) -> LunarMirrorReconcilePlan {
        LunarMirrorPolicy.reconcile(
            baseID: baseID,
            currentDate: currentDate,
            origin: origin,
            spec: spec,
            isLunar: isLunar,
            validStart: validStart,
            validEnd: validEnd,
            completedDates: completedDates,
            now: now,
            existing: existing,
            knownKeys: knownKeys,
            suppressedKeys: suppressedKeys,
            expectedFingerprint: expectedFingerprint,
            skipHolidays: skipHolidays,
            isRestDay: isRestDay,
            calendar: calendar
        )
    }
}
