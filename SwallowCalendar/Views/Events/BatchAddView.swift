//
//  BatchAddView.swift
//  SwallowCalendar
//
//  批量添加弹窗：多行输入，每行一条事件任务（spec: batch-add-events）
//

import SwiftUI
import os

struct BatchAddView: View {
    @Environment(AppSettings.self) private var appSettings
    let calendarService: CalendarService
    var onClose: () -> Void
    var onTaskAdded: () -> Void

    @State private var text = ""
    @State private var isProcessing = false
    @State private var result: BatchAddResult?

    private var validLineCount: Int {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .count
    }
    private var isOverLimit: Bool { validLineCount > BatchAddParser.maxLines }

    var body: some View {
        VStack(spacing: 0) {
            editorArea

            if isOverLimit {
                Text("单次最多 \(BatchAddParser.maxLines) 行，超出部分将被忽略")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }

            Divider()

            if let result {
                resultSummary(result)
            } else {
                actionBar
            }
        }
        .frame(minWidth: 420, minHeight: 320)
    }

    // MARK: - 编辑区

    private var editorArea: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text("每行一条，如：\n明天下午3点开会 红色 重要\n每天上午9点晨会 循环")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary.opacity(0.6))
                    .padding(12)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .disabled(result != nil || isProcessing)
        }
        .padding(8)
    }

    // MARK: - 操作栏

    private var actionBar: some View {
        HStack(spacing: 8) {
            Text("\(validLineCount) 条")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            Spacer()

            Button("取消") { onClose() }
                .keyboardShortcut(.cancelAction)

            Button {
                submit()
            } label: {
                if isProcessing {
                    ProgressView().controlSize(.small)
                } else {
                    Text("批量添加")
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(isProcessing || validLineCount == 0)
        }
        .padding(10)
    }

    // MARK: - 结果汇总（部分失败时展示，失败行已回填编辑区）

    private func resultSummary(_ result: BatchAddResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: result.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(result.failures.isEmpty ? .green : .orange)
                Text(result.failures.isEmpty
                     ? "成功添加 \(result.successCount) 条"
                     : "成功 \(result.successCount) 条 / 失败 \(result.failures.count) 条")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
            }

            ForEach(result.failures) { failure in
                HStack(spacing: 6) {
                    Text(failure.rawText)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    Text(failure.reason)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                }
            }

            HStack {
                Spacer()
                Button(result.failures.isEmpty ? "完成" : "继续编辑") {
                    if result.failures.isEmpty {
                        onClose()
                    } else {
                        self.result = nil
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
    }

    // MARK: - 提交

    private func submit() {
        let lines = BatchAddParser.prepareLines(text)
        guard !lines.isEmpty, !isProcessing else { return }

        isProcessing = true

        Task { @MainActor in
            var successCount = 0
            var failures: [BatchAddFailure] = []
            for line in lines {
                do {
                    // 创建参数与 TaskInputView.addTask 单条链路一致（批量无手动编辑覆盖）
                    try calendarService.createEvent(
                        title: line.parsed.title,
                        startDate: line.parsed.date,
                        endDate: line.parsed.date.addingTimeInterval(3600),  // 非全天默认结束 = 开始 +1h
                        isAllDay: false,                                     // 批量无全天开关，沿用 V-16 不隐式判全天
                        calendar: nil,
                        priority: line.parsed.priority,
                        recurrence: line.parsed.recurrence ?? RecurrenceType.none,
                        reminderMinutes: line.parsed.reminderMinutes ?? 10,  // 与单条默认提醒一致
                        category: .user,
                        asReminder: false,
                        isLunar: line.parsed.isLunar,
                        color: line.parsed.color
                    )
                    successCount += 1
                } catch {
                    AppLogger.ui.error("批量添加失败: \(String(describing: error))")
                    failures.append(BatchAddFailure(rawText: line.rawText, reason: "写入日历失败"))
                }
            }
            isProcessing = false

            onTaskAdded()

            if failures.isEmpty {
                onClose()  // 全部成功自动关闭
            } else {
                // 成功行移出编辑区，失败行回填供修正重试
                text = failures.map(\.rawText).joined(separator: "\n")
                result = BatchAddResult(successCount: successCount, failures: failures)
            }
        }
    }
}

// MARK: - 提交结果模型

private struct BatchAddFailure: Identifiable {
    let id = UUID()
    let rawText: String
    let reason: String
}

private struct BatchAddResult {
    let successCount: Int
    let failures: [BatchAddFailure]
}
