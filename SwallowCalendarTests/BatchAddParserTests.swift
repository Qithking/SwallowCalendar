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
}
