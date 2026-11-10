//
//  BatchAddParserTests.swift
//  SwallowCalendarTests
//
//  批量添加行准备逻辑测试（spec: batch-add-events AC-3/AC-4 + 行数上限假设）
//

import XCTest
@testable import SwallowCalendar

class BatchAddParserTests: XCTestCase {

    // AC-4：空行/纯空白行被过滤，不计入条数
    func testPrepareLinesFiltersBlankLines() {
        let lines = BatchAddParser.prepareLines("明天下午3点开会\n\n   \n后天上午10点体检")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].rawText, "明天下午3点开会")
        XCTAssertEqual(lines[1].rawText, "后天上午10点体检")
    }

    // AC-3：每行解析与主输入框单条解析一致（同一 NLPTaskParser.parse 链路）
    func testPrepareLinesParsesEachLine() {
        let lines = BatchAddParser.prepareLines("明天下午3点开会 红色 重要\n每天上午9点晨会 循环")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].parsed.title, "开会")
        XCTAssertEqual(lines[0].parsed.color, .red)
        XCTAssertEqual(lines[0].parsed.priority, .high)
        XCTAssertEqual(lines[1].parsed.title, "晨会")
        XCTAssertEqual(lines[1].parsed.recurrence, .daily)
    }

    // 无有效标题的行由 NLPTaskParser 兜底"待办事项"，批量与单条行为一致
    func testUntitledLineFallsBackToDefaultTitle() {
        let lines = BatchAddParser.prepareLines("红色")
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].parsed.title, "待办事项")
    }

    // Assumption：单次行数上限 100，超出截断
    func testPrepareLinesTruncatesToLimit() {
        let text = (1...105).map { "任务\($0)" }.joined(separator: "\n")
        XCTAssertEqual(BatchAddParser.prepareLines(text).count, 100)
    }

    // R-11：CRLF 粘贴（Windows 文本）行尾 \r 必须被清除，不得残留进标题；
    // 纯 \r 空行也应被过滤不计条数
    func testPrepareLinesStripsCRLF() {
        let lines = BatchAddParser.prepareLines("明天下午3点开会\r\n\r\n后天上午10点体检")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].rawText, "明天下午3点开会", "行尾 \\r 残留会进标题落库")
        XCTAssertEqual(lines[1].rawText, "后天上午10点体检")
    }
}

// MARK: - 批量公共属性合并（行内 NLP 解析优先，公共值兜底）

class BatchAddCommonAttributesTests: XCTestCase {

    // 行内解析出的字段优先：行文本写明「红色/重要/提前30分钟」时不被公共值覆盖；
    // 行内解析出周期时按行内类型 + 行内日期推导 spec（公共周期不覆盖行内解析）
    func testResolvingPrefersInlineParsedFields() {
        let common = BatchAddCommonAttributes(
            color: .blue,
            priority: .low,
            spec: RecurrenceSpec.legacy(from: .weekly, anchor: Date(timeIntervalSince1970: 0), isLunar: false),
            reminderOffsets: [10]
        )
        var parsed = ParsedTask(title: "开会", date: Date(timeIntervalSince1970: 1_000_000))
        parsed.color = .red
        parsed.priority = .high
        parsed.recurrence = .daily
        parsed.reminderMinutes = 30

        let row = common.resolving(parsed)

        XCTAssertEqual(row.color, .red)
        XCTAssertEqual(row.priority, .high)
        XCTAssertEqual(row.reminderOffsets, [30])
        XCTAssertEqual(row.spec?.legacyType, .daily)
    }

    // 行内未解析的字段用公共值兜底；农历取 OR（行内提及或公共开启任一即生效）
    func testResolvingFallsBackToCommonAndOrsLunar() {
        let anchor = Date(timeIntervalSince1970: 1_000_000)
        let common = BatchAddCommonAttributes(
            color: .blue,
            priority: .medium,
            spec: RecurrenceSpec.legacy(from: .weekly, anchor: anchor, isLunar: false),
            isLunar: true,
            reminderOffsets: [10]
        )
        var parsed = ParsedTask(title: "待办", date: anchor)
        parsed.isLunar = true

        let row = common.resolving(parsed)

        XCTAssertEqual(row.color, .blue)
        XCTAssertEqual(row.priority, .medium)
        XCTAssertEqual(row.reminderOffsets, [10])
        XCTAssertTrue(row.isLunar)
        XCTAssertEqual(row.spec, RecurrenceSpec.legacy(from: .weekly, anchor: anchor, isLunar: false))
    }

    // 公共区全部保持默认且行内未解析 → 与现有批量行为一致（无颜色/无优先级/1次/无提醒/非农历）
    func testResolvingWithAllDefaultsKeepsLegacyBehavior() {
        let parsed = ParsedTask(title: "待办", date: Date(timeIntervalSince1970: 0))

        let row = BatchAddCommonAttributes().resolving(parsed)

        XCTAssertNil(row.color)
        XCTAssertEqual(row.priority, .none)
        XCTAssertNil(row.spec)
        XCTAssertNil(row.reminderOffsets)
        XCTAssertFalse(row.isLunar)
    }
}
