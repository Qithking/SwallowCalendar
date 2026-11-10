//
//  BatchAddParser.swift
//  SwallowCalendar
//
//  批量添加：行准备逻辑（spec: batch-add-events）
//

import Foundation

/// 批量添加的单行解析结果：保留原文（供失败行回显重试）+ NLP 解析结果
struct BatchAddLine {
    let rawText: String
    let parsed: ParsedTask
}

/// 批量添加行准备：拆行、过滤空白行、逐行 NLP 解析
/// 每行与主输入框走同一 NLPTaskParser.parse 链路，保证批量/单条解析结果一致
enum BatchAddParser {
    /// 单次行数上限，防误粘贴超大文本
    static let maxLines = 100

    static func prepareLines(_ text: String, limit: Int = maxLines) -> [BatchAddLine] {
        text
            // 必须用 whereSeparator 拆行——CRLF 的 \r\n 在 Swift 中合并为单个
            // Character（grapheme cluster），它 ≠ "\n"，split(separator: "\n") 对
            // Windows 粘贴文本整个不拆行（全部文本合成一条任务）；isNewline 对
            // \n、\r、\r\n 合成字符均返回 true，三种换行都能正确拆分
            .split(whereSeparator: { $0.isNewline })
            // whitespacesAndNewlines 兜底清除行首尾残留空白（含孤立 \r）
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(limit)
            .map { BatchAddLine(rawText: $0, parsed: NLPTaskParser.parse($0)) }
    }
}

// MARK: - 批量公共属性（「更多选项」区 → 各行默认值）

/// 批量新增公共属性：作为该批全部行的默认值；
/// 行内 NLP 解析出的字段优先（如行文本写明「红色」时不被公共颜色覆盖）
struct BatchAddCommonAttributes: Equatable {
    var color: EventColor? = nil
    var priority: EventPriority = .none
    /// 公共周期规则（nil = 1 次）；行内解析出周期时按行内类型 + 行内日期推导
    var spec: RecurrenceSpec? = nil
    var isLunar: Bool = false
    var reminderOffsets: [Int]? = nil

    /// 合并行内解析结果：行内字段优先，公共值兜底；农历取 OR（任一开启即生效）
    func resolving(_ parsed: ParsedTask) -> BatchAddResolvedRow {
        let isLunar = parsed.isLunar || self.isLunar
        let spec: RecurrenceSpec?
        if let inline = parsed.recurrence {
            // 行内周期按行内日期锚定（如 monthly 的 monthDay 取行内日）
            spec = RecurrenceSpec.legacy(from: inline, anchor: parsed.date, isLunar: isLunar)
        } else {
            spec = self.spec
        }
        return BatchAddResolvedRow(
            color: parsed.color ?? color,
            priority: parsed.priority ?? priority,
            spec: spec,
            isLunar: isLunar,
            reminderOffsets: parsed.reminderMinutes.map { [$0] } ?? reminderOffsets
        )
    }
}

/// 合并后的单行创建参数（供批量提交组装 createEvent；asReminder/validity 为纯公共字段不参与合并）
struct BatchAddResolvedRow: Equatable {
    var color: EventColor?
    var priority: EventPriority
    var spec: RecurrenceSpec?
    var isLunar: Bool
    var reminderOffsets: [Int]?
}
