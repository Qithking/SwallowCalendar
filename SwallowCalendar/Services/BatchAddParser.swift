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
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(limit)
            .map { BatchAddLine(rawText: $0, parsed: NLPTaskParser.parse($0)) }
    }
}
