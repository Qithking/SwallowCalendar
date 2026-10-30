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
            // R-11：必须用 whereSeparator 拆行——CRLF 的 \r\n 在 Swift 中合并为单个
            // Character（grapheme cluster），它 ≠ "\n"，split(separator: "\n") 对
            // Windows 粘贴文本整个不拆行（全部文本合成一条任务）；isNewline 对
            // \n、\r、\r\n 合成字符均返回 true，三种换行都能正确拆分
            .split(whereSeparator: { $0.isNewline })
            // R-11：whitespacesAndNewlines 兜底清除行首尾残留空白（含孤立 \r）
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(limit)
            .map { BatchAddLine(rawText: $0, parsed: NLPTaskParser.parse($0)) }
    }
}
