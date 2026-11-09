//
//  LunarMirrorPolicy.swift
//  SwallowCalendar
//
//  农历镜像生命周期的单一判定源（纯函数）：无 I/O、无 SwiftData、无 EventKit。
//  四类输出集中在此：
//  1. capability / hint —— 是否该镜像、UI 该说什么；
//  2. occurrences / desiredDates —— 某时刻应存在哪些期次；
//  3. reconcile —— 一次对账应创建/更新/删除/登记哪些键。
//  依赖仅 OccurrenceID（纯工具）与 RecurrenceSpec（纯模型）；
//  禁止 import SwiftData / EventKit，禁止反向依赖 CalendarService / Views。
//

import Foundation
import os

// MARK: - 值输入

/// 镜像载体（提醒 / 日历事件）
enum MirrorCarrier: String, Sendable, Equatable {
    case reminder
    case event
}

/// 已创建键登记与手删抑制（值类型快照，禁止跨 await 持有模型）
struct MirrorRegistry: Sendable, Equatable {
    var knownKeys: [String] = []
    var suppressedKeys: [String] = []
}

/// 与「期次枚举」相关的纯输入
struct LunarMirrorSchedule: Sendable, Equatable {
    let spec: RecurrenceSpec?
    let isLunar: Bool
    /// 当前期（本体承担，不作为镜像起点之后的下界）；nil = 无当前期
    let currentDate: Date?
    let origin: Date
    let validStart: Date?
    let validEnd: Date?
    let skipHolidays: Bool
}

/// 一个 base 的完整纯值快照
struct LunarMirrorBase: Sendable, Equatable {
    let baseID: String
    let carrier: MirrorCarrier
    let schedule: LunarMirrorSchedule
    let completedDates: [Date]
    let registry: MirrorRegistry
    /// 本体当前内容指纹（nil = 不校验，不做原地更新）
    let contentFingerprint: String?

    var spec: RecurrenceSpec? { schedule.spec }
    var isLunar: Bool { schedule.isLunar }
    var currentDate: Date? { schedule.currentDate }
}

// MARK: - 输出

/// 是否该镜像（含开关可用性判定）
enum MirrorCapability: Equatable, Sendable {
    case mirrorAvailable
    case localOnly(LocalOnlyReason)
    case specMissing

    enum LocalOnlyReason: String, Equatable, Sendable {
        /// 非农历：由公历规则承担，不需要镜像
        case notLunar
        /// 频度不需要公历换算（daily/weekly/hourly/custom）
        case frequency
        /// 无当前期可作起点
        case noCurrentOccurrence
    }
}

/// UI 提示（条件在 policy，文案由 View 映射）
enum MirrorHint: Equatable, Sendable {
    /// 将在系统提醒事项中按公历日期创建对应提醒
    case systemMirrors
    /// 农历已开启但当前频度与公历等价，仅应用内生效
    case localOnlyFrequency
    /// 未设置重复周期（单期）：农历开关不可用
    case specMissing
}

/// 一个农历期次换算出的公历日期
struct LunarMirrorOccurrence: Equatable {
    /// RecurrenceSpec 期序号（用于 end 条件与调试）
    let index: Int
    /// 换算后的公历绝对日期（含原 origin 的时分秒）
    let date: Date
}

/// 系统侧已存在的镜像（按 notes 标记识别）
struct ExistingLunarMirror: Sendable, Equatable {
    let occurrenceID: String
    let date: Date
    let isCompleted: Bool
    /// 镜像写入时的内容指纹（旧镜像无该段时为 nil → 首轮对账补写）
    var contentFingerprint: String? = nil
}

/// 一次镜像对账计划（纯数据，便于无日历授权环境单测）
struct LunarMirrorReconcilePlan: Equatable {
    /// 需要新建镜像的公历日期
    var createDates: [Date] = []
    /// 需要原地更新内容的镜像复合 ID（期次不变、本体标题/提醒/优先级/列表变更）
    var updateOccurrenceIDs: [String] = []
    /// 需要删除的镜像复合 ID（未来未完成）
    var deleteOccurrenceIDs: [String] = []
    /// 需要标记完成的镜像复合 ID（应用内已完成的历史镜像）
    var completeOccurrenceIDs: [String] = []
    /// 需要写入「已创建键登记」的键（新创建成功由调用方追加；此处仅含系统侧已有的收养键）
    var knownKeysToAdd: [String] = []
    /// 需要从「已创建键登记」移除的键（本次删除 / 被判定为手删 / 已过期清理）
    var knownKeysToRemove: [String] = []
    /// 需要新增的抑制键（系统侧缺失且曾创建成功 → 判定为手删）
    var suppressedKeysToAdd: [String] = []
    /// 需要移除的抑制键（期次已过期，抑制不再有意义）
    var suppressedKeysToRemove: [String] = []
}

// MARK: - 循环规则状态

/// 规则解析状态：`corrupt` 是独立失败态，绝不允许降级成 `.none`（否则会被当成「取消农历」）
enum SpecState: Sendable, Equatable {
    case valid(RecurrenceSpec)
    case none
    case corrupt

    var spec: RecurrenceSpec? {
        if case let .valid(spec) = self { return spec }
        return nil
    }

    var isCorrupt: Bool { self == .corrupt }
}

// MARK: - 系统侧存在性

/// 系统侧完整快照：可用于「判定不存在」与删除
struct CompletePresence: Sendable, Equatable {
    let ids: Set<String>
    let observedAt: Date
}

/// 系统侧窗口快照：只能用于去重/收养，不得用于删除
struct WindowedPresence: Sendable, Equatable {
    let ids: Set<String>
    let range: Range<Date>
}

/// 读取失败原因（不得等价于「系统侧为空」）
enum MirrorReadFailure: String, Sendable, Equatable {
    case notAuthorized
    case queryFailed
}

/// 系统侧存在性三态
enum SystemPresence: Sendable, Equatable {
    case complete(CompletePresence)
    case windowed(WindowedPresence)
    case unavailable(MirrorReadFailure)
}

// MARK: - 判定源

enum LunarMirrorPolicy {
    // MARK: 是否该镜像

    /// 农历镜像启用频度：仅每月/每年需要公历换算镜像。
    /// 每天/每周的农历推进与公历完全一致，镜像纯冗余，禁止进批量写入（H1）。
    static func supportsMirror(frequency: RecurrenceFrequency) -> Bool {
        frequency == .monthly || frequency == .yearly
    }

    /// 是否启用系统侧镜像（对账、批量预筛、UI 提示同一判定源）
    /// - Note: 「农历 + 有规则 + monthly/yearly」才写系统侧；其余仅应用内生效
    static func isMirrorEnabled(isLunar: Bool, frequency: RecurrenceFrequency?) -> Bool {
        guard isLunar, let frequency else { return false }
        return supportsMirror(frequency: frequency)
    }

    static func isMirrorEnabled(isLunar: Bool, spec: RecurrenceSpec?) -> Bool {
        isMirrorEnabled(isLunar: isLunar, frequency: spec?.frequency)
    }

    /// 开关可用性与对账口径（A1/A2/A3 收敛）
    static func capability(_ base: LunarMirrorBase) -> MirrorCapability {
        guard let spec = base.spec else { return .specMissing }
        guard base.isLunar else { return .localOnly(.notLunar) }
        guard supportsMirror(frequency: spec.frequency) else { return .localOnly(.frequency) }
        guard base.currentDate != nil else { return .localOnly(.noCurrentOccurrence) }
        return .mirrorAvailable
    }

    /// 农历开关是否可用：无规则/单期时不生效，UI 必须置灰并给出说明
    static func isLunarToggleEnabled(spec: RecurrenceSpec?) -> Bool {
        spec != nil
    }

    /// UI 提示条件（文案在 View 层映射）
    static func hint(isLunar: Bool, spec: RecurrenceSpec?) -> MirrorHint? {
        guard let spec else { return .specMissing }
        guard isLunar else { return nil }
        return isMirrorEnabled(isLunar: isLunar, spec: spec) ? .systemMirrors : .localOnlyFrequency
    }

    static func hint(_ base: LunarMirrorBase) -> MirrorHint? {
        hint(isLunar: base.isLunar, spec: base.spec)
    }

    // MARK: 期次枚举

    /// 窗口长度（月）
    static let windowMonths = 12
    /// 尾端补满阈值（月）：剩余覆盖不足该值时补满到 windowMonths
    static let topUpMonths = 3

    /// 镜像生成终点：无镜像或尾端不足 3 个月 → now + 12 个月；否则维持现有最远日期（不补）
    static func horizon(now: Date, furthestMirror: Date?, calendar: Calendar = .current) -> Date {
        let full = calendar.date(byAdding: .month, value: windowMonths, to: now) ?? now
        let threshold = calendar.date(byAdding: .month, value: topUpMonths, to: now) ?? now
        guard let furthestMirror, furthestMirror >= threshold else { return full }
        return furthestMirror
    }

    /// 枚举 (lowerBound, upperBound] 内的农历期次并换算为公历日期
    /// - Parameters:
    ///   - spec: 农历循环规则（仅 monthly/yearly 生效，其余频度直接返回空）
    ///   - origin: 序列锚点（originStartDate ?? startDate）
    ///   - lowerBound: 开区间下界（base 当前期本身由本体承担，不重复镜像）
    ///   - upperBound: 闭区间上界（horizon）
    /// - Note: 期次推进复用 RecurrenceSpec.occurrence(index:origin:isLunar:)，与展开同一份索引；
    ///         闰月正常生成；大小月沿用系统 Calendar 的 date(byAdding:) 语义
    static func occurrences(
        spec: RecurrenceSpec,
        origin: Date,
        after lowerBound: Date,
        through upperBound: Date
    ) -> [LunarMirrorOccurrence] {
        guard upperBound > lowerBound, supportsMirror(frequency: spec.frequency) else { return [] }

        var index = max(0, spec.index(of: lowerBound, origin: origin, isLunar: true) ?? 0)

        // 估算对齐：回退到首个可能 > lowerBound 的 index（估算误差兜底 800 期）
        var guardCount = 0
        while index > 0, guardCount < 800,
              let prev = spec.occurrence(index: index - 1, origin: origin, isLunar: true),
              prev > lowerBound {
            index -= 1
            guardCount += 1
        }
        // 前进到首个 > lowerBound 的期次（跳过下界本身）
        var aligned = false
        guardCount = 0
        while guardCount < 800 {
            guard let current = spec.occurrence(index: index, origin: origin, isLunar: true) else {
                index += 1
                guardCount += 1
                continue
            }
            if current > lowerBound {
                aligned = true
                break
            }
            index += 1
            guardCount += 1
        }
        // M4：对齐耗尽预算仍找不到下界之后的期次 → 直接返回空，禁止带病枚举出历史期次
        guard aligned else {
            AppLogger.cache.error("农历镜像期次对齐失败，本次不产出镜像 origin=\(origin, privacy: .public) lower=\(lowerBound, privacy: .public)")
            return []
        }

        var result: [LunarMirrorOccurrence] = []
        var cursor = index
        var iterations = 0
        while iterations < 4000 {
            guard spec.allows(index: cursor, origin: origin, isLunar: true) else { break }
            guard let date = spec.occurrence(index: cursor, origin: origin, isLunar: true) else {
                cursor += 1
                iterations += 1
                continue
            }
            if date > upperBound { break }
            // M4：兜底保证输出严格在下界之后（对齐估算偏差时不会产出 ≤ lowerBound 的日期）
            if date <= lowerBound {
                cursor += 1
                iterations += 1
                continue
            }
            result.append(LunarMirrorOccurrence(index: cursor, date: date))
            cursor += 1
            iterations += 1
        }
        return result
    }

    /// 某时刻应存在哪些期次（B2 过滤链单一入口）
    /// - Parameters:
    ///   - from: 下界（当前期；开区间）
    ///   - horizon: 上界（闭区间）
    static func desiredDates(
        schedule: LunarMirrorSchedule,
        from lowerBound: Date,
        now: Date,
        horizon: Date,
        isRestDay: ((Date) -> Bool)? = nil
    ) -> [Date] {
        guard isMirrorEnabled(isLunar: schedule.isLunar, spec: schedule.spec),
              let spec = schedule.spec else { return [] }
        return occurrences(spec: spec, origin: schedule.origin, after: lowerBound, through: horizon)
            .map(\.date)
            .filter { date in
                // M1：提醒侧 currentDate 可能早于 now，过期期次一律不补建，
                // 与删除路径「只删未来」对齐；也避免手删的过期镜像被复活
                guard date > now else { return false }
                // M2：与应用内展开同一口径，休日不铺系统镜像；不写抑制，未来规则变化可重新纳入
                if schedule.skipHolidays, let isRestDay, isRestDay(date) { return false }
                if let validStart = schedule.validStart, date < validStart { return false }
                if let validEnd = schedule.validEnd, date > validEnd { return false }
                return true
            }
    }

    // MARK: 删除判据（单一实现）

    /// 删除场景：只决定「未来未完成」之外是否还有额外条件，不再各写一套过滤
    enum DeletionScope: Equatable, Sendable {
        /// 取消农历 / 转单次：删除未来未完成镜像
        case cancelOrDisable
        /// 应用内删除 base：与取消农历同口径
        case baseRemoved
        /// 孤儿清扫：base 在缓存与完整系统快照都不存在，与取消农历同口径
        case orphan
        /// 规则变更 / 当前期推进：未来未完成且不在期望期次内，或恰为当前期（冗余）
        case noLongerDesired(desiredEpochs: Set<Int>, currentEpoch: Int?)
    }

    /// 孤儿 base 判定：镜像所属 base 既不在缓存、也不在系统完整快照
    /// - Parameter presence: 只接受 `CompletePresence?`；窗口快照在类型层面无法进入删除判定，
    ///   读取失败（nil）时返回空集，绝不把失败等价成「系统侧为空」
    static func orphanBaseIDs(
        cachedBaseIDs: Set<String>,
        mirrorBaseIDs: Set<String>,
        presence: CompletePresence?
    ) -> Set<String> {
        guard let presence else { return [] }
        return mirrorBaseIDs.subtracting(cachedBaseIDs).subtracting(presence.ids)
    }

    /// 应删除的镜像键（三套删除实现的唯一入口）
    static func keysToDelete(
        scope: DeletionScope,
        existing: [ExistingLunarMirror],
        now: Date
    ) -> [String] {
        existing.filter { isDeletable($0, scope: scope, now: now) }.map(\.occurrenceID)
    }

    /// 删除判据唯一实现：已完成历史永不删除；过期未完成保持现状（EXPIRY 口径未变更）
    private static func isDeletable(
        _ mirror: ExistingLunarMirror,
        scope: DeletionScope,
        now: Date
    ) -> Bool {
        guard !mirror.isCompleted else { return false }
        switch scope {
        case .cancelOrDisable, .baseRemoved, .orphan:
            return mirror.date > now
        case let .noLongerDesired(desiredEpochs, currentEpoch):
            let epoch = Int(mirror.date.timeIntervalSince1970)
            // 本体已推进到该期：镜像冗余，即使已过期也删除（与历史行为一致）
            if let currentEpoch, epoch == currentEpoch { return true }
            return mirror.date > now && !desiredEpochs.contains(epoch)
        }
    }

    // MARK: 对账计划

    /// 生成一次对账计划：
    /// - 启用镜像（农历 + monthly/yearly + 有规则）：补齐窗口内缺失期次；本体当前期由 base 承担，不生成镜像；
    /// - 完成推进：新当前期若已有未完成镜像 → 删除；应用内已完成历史 → 标记对应镜像完成并保留；
    /// - 停用/取消农历：删除未来未完成镜像，历史（已完成/已过期）保留；
    /// - 规则变更：未来未完成且不在新期次集合内的镜像删除，已完成保留；
    /// - 手删抑制：登记里有、系统侧没有、且未抑制的未来键 → 判定为手删，写入抑制并不再重建。
    static func reconcile(
        baseID: String,
        currentDate: Date?,
        origin: Date,
        specState: SpecState,
        isLunar: Bool,
        validStart: Date?,
        validEnd: Date?,
        completedDates: [Date],
        now: Date,
        existing: [ExistingLunarMirror],
        knownKeys: [String] = [],
        suppressedKeys: [String] = [],
        suppressedKeysUnavailable: Bool = false,
        expectedFingerprint: String? = nil,
        skipHolidays: Bool = false,
        isRestDay: ((Date) -> Bool)? = nil,
        calendar: Calendar = .current
    ) -> LunarMirrorReconcilePlan {
        // S5：规则 JSON 损坏 ≠ 取消农历——不清镜像、不改变现状，只留可诊断日志
        guard !specState.isCorrupt else {
            AppLogger.cache.error("农历镜像对账跳过：循环规则 JSON 损坏 base=\(baseID, privacy: .public)")
            return LunarMirrorReconcilePlan()
        }
        let spec = specState.spec
        var plan = LunarMirrorReconcilePlan()
        let enabled = isMirrorEnabled(isLunar: isLunar, spec: spec) && currentDate != nil

        // 只处理本 base 的键：抑制/登记不跨 base 串味
        let ownKnown = knownKeys.filter { OccurrenceID.parse($0)?.baseID == baseID }
        let ownSuppressed = suppressedKeys.filter { OccurrenceID.parse($0)?.baseID == baseID }
        let relevantExisting = existing.filter { OccurrenceID.parse($0.occurrenceID)?.baseID == baseID }

        let furthest = relevantExisting.map(\.date).max()
        let horizonDate = horizon(now: now, furthestMirror: furthest, calendar: calendar)

        var desiredDates: [Date] = []
        if enabled, let currentDate {
            desiredDates = self.desiredDates(
                schedule: LunarMirrorSchedule(
                    spec: spec,
                    isLunar: isLunar,
                    currentDate: currentDate,
                    origin: origin,
                    validStart: validStart,
                    validEnd: validEnd,
                    skipHolidays: skipHolidays
                ),
                from: currentDate,
                now: now,
                horizon: horizonDate,
                isRestDay: isRestDay
            )
        }

        let epoch: (Date) -> Int = { Int($0.timeIntervalSince1970) }
        let completedEpochs = Set(completedDates.map(epoch))
        let desiredEpochs = Set(desiredDates.map(epoch))
        let existingEpochs = Set(relevantExisting.map { epoch($0.date) })
        let existingKeys = Set(relevantExisting.map(\.occurrenceID))
        let suppressedEpochs = Set(ownSuppressed.compactMap { OccurrenceID.parse($0)?.occurrence }.map(epoch))

        // 完成推进：应用内已完成 → 标记系统侧完成并保留历史（不参与删除）
        for mirror in relevantExisting where !mirror.isCompleted {
            if completedEpochs.contains(epoch(mirror.date)) {
                plan.completeOccurrenceIDs.append(mirror.occurrenceID)
            }
        }
        // 删除：三套实现共用 keysToDelete；已完成历史先从候选集中剔除
        let deleteCandidates = relevantExisting.filter { !completedEpochs.contains(epoch($0.date)) }
        let scope: DeletionScope = enabled
            ? .noLongerDesired(desiredEpochs: desiredEpochs, currentEpoch: currentDate.map(epoch))
            : .cancelOrDisable
        plan.deleteOccurrenceIDs = keysToDelete(scope: scope, existing: deleteCandidates, now: now)

        // 登记维护：本次删除的键移出登记（无论是否在登记中，移除幂等）
        let deletedKeys = Set(plan.deleteOccurrenceIDs)
        // H2：内容指纹漂移（标题/提醒/优先级/列表变更）→ 原地更新保留的未来镜像
        if enabled, let expectedFingerprint {
            for mirror in relevantExisting
            where !mirror.isCompleted
                && !deletedKeys.contains(mirror.occurrenceID)
                && desiredEpochs.contains(epoch(mirror.date))
                && mirror.contentFingerprint != expectedFingerprint {
                plan.updateOccurrenceIDs.append(mirror.occurrenceID)
            }
            plan.updateOccurrenceIDs = Array(Set(plan.updateOccurrenceIDs))
        }
        plan.knownKeysToRemove.append(contentsOf: deletedKeys)
        // 收养：系统侧已有、登记缺失（含用户手删后恢复的镜像）
        for key in existingKeys where !ownKnown.contains(key) && !deletedKeys.contains(key) {
            plan.knownKeysToAdd.append(key)
        }
        // 判定手删：登记有、系统侧无、未抑制；未来键 → 抑制，过期键 → 直接移出登记
        for key in ownKnown where !existingKeys.contains(key) {
            guard let parsed = OccurrenceID.parse(key) else {
                plan.knownKeysToRemove.append(key)
                continue
            }
            // S5：抑制列表损坏 ≠ 空列表——本轮不判定手删、不改写登记，等数据恢复
            guard !suppressedKeysUnavailable else { continue }
            if ownSuppressed.contains(key) { continue }
            if parsed.occurrence > now {
                plan.suppressedKeysToAdd.append(key)
                plan.knownKeysToRemove.append(key)
            } else {
                plan.knownKeysToRemove.append(key)
            }
        }
        // 抑制清理：期次已过期，或镜像已重新出现（视为恢复）→ 解除抑制
        if !suppressedKeysUnavailable {
            for key in ownSuppressed {
                if existingKeys.contains(key) {
                    plan.suppressedKeysToRemove.append(key)
                } else if let parsed = OccurrenceID.parse(key), parsed.occurrence <= now {
                    plan.suppressedKeysToRemove.append(key)
                }
            }
        }

        // 新建：跳过已存在、有效抑制（含本次刚判定手删）、已完成历史已覆盖的期次
        // S5：抑制列表不可用时无法区分「手删」与「未创建」，该 base 本轮跳过重建
        let newlySuppressedEpochs = Set(
            plan.suppressedKeysToAdd.compactMap { OccurrenceID.parse($0)?.occurrence }.map(epoch)
        )
        let effectiveSuppressedEpochs = suppressedEpochs.union(newlySuppressedEpochs)
        if !suppressedKeysUnavailable {
            for date in desiredDates
            where !existingEpochs.contains(epoch(date)) && !effectiveSuppressedEpochs.contains(epoch(date)) {
                plan.createDates.append(date)
            }
        }

        // 去重，避免同键同时出现在 add/remove
        plan.knownKeysToRemove = Array(Set(plan.knownKeysToRemove))
        plan.knownKeysToAdd = Array(Set(plan.knownKeysToAdd).subtracting(plan.knownKeysToRemove))
        plan.suppressedKeysToRemove = Array(Set(plan.suppressedKeysToRemove))
        plan.suppressedKeysToAdd = Array(Set(plan.suppressedKeysToAdd).subtracting(plan.suppressedKeysToRemove))
        return plan
    }

    /// 兼容入口：`RecurrenceSpec?` 等价于 `.valid` / `.none`，不含损坏语义。
    /// 真正需要区分「损坏 ≠ 取消农历」的调用必须用 `specState:` 重载
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
        reconcile(
            baseID: baseID,
            currentDate: currentDate,
            origin: origin,
            specState: spec.map(SpecState.valid) ?? .none,
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
