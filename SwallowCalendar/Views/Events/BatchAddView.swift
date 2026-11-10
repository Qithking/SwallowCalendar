//
//  BatchAddView.swift
//  SwallowCalendar
//
//  批量添加弹窗：多行输入，每行一条事件任务（spec: batch-add-events）
//

import SwiftUI
import os

/// 截图取证用预览态：仅 SC_OPEN_BATCH_ADD_PREVIEW 入口使用（正常路径为 nil，不生效）
struct BatchAddPreviewState {
    var sampleText: String
    /// >0 时首帧展示「部分失败」结果，用于验证内容增多后的高态
    var failureCount: Int = 0
}

struct BatchAddView: View {
    @Environment(AppSettings.self) private var appSettings
    let calendarService: CalendarService
    var onClose: () -> Void
    var onTaskAdded: () -> Void
    /// 内容自然高度回调：由窗口侧顶部锚定调整高度（与编辑窗口同一套做法）
    var onContentHeightChange: ((CGFloat) -> Void)?

    @State private var text: String
    @State private var isProcessing = false
    @State private var result: BatchAddResult?
    // 「更多选项」公共属性区：作用于全部行（行内 NLP 解析出的字段优先，公共值兜底）
    @State private var isMoreOptionsExpanded = false
    @State private var commonColor: EventColor?
    @State private var commonPriority: EventPriority = .none
    @State private var commonPreset: RecurrencePreset = .never
    @State private var commonSpec: RecurrenceSpec?
    @State private var commonIsLunar = false
    @State private var commonOffsets: [Int] = []
    @State private var createAsReminder = false
    @State private var validityEnabled = false
    @State private var validityHasStart = false
    @State private var validityStart = Date()
    @State private var validityHasEnd = false
    @State private var validityEnd = Date()
    /// 最近一次测量的内容自然高度（用于决定是否启用内部滚动）
    @State private var contentHeight: CGFloat = 0

    /// 窗口内容宽度（与编辑窗口一致：宽度固定，只有高度随内容变化）
    static let contentWidth: CGFloat = 420
    /// 编辑区固定高度：TextEditor 自身可滚动，窗口高度只随「编辑区 + 底部区」的自然高度变化
    static let editorAreaHeight: CGFloat = 276
    /// 内容自适应上限：超过后窗口不再长高，改为内部滚动（覆盖部分失败时的多条失败行）；
    /// 上限需容纳「更多选项」完全展开后的高度（约 750px），避免展开瞬间出内部滚动条
    static let maxContentHeight: CGFloat = 800

    init(
        calendarService: CalendarService,
        onClose: @escaping () -> Void,
        onTaskAdded: @escaping () -> Void,
        preview: BatchAddPreviewState? = nil,
        onContentHeightChange: ((CGFloat) -> Void)? = nil
    ) {
        self.calendarService = calendarService
        self.onClose = onClose
        self.onTaskAdded = onTaskAdded
        self.onContentHeightChange = onContentHeightChange
        if let failureCount = preview?.failureCount, failureCount > 0 {
            let failures = (1...failureCount).map {
                BatchAddFailure(rawText: "示例失败行 \($0)", reason: "写入日历失败")
            }
            _text = State(initialValue: failures.map(\.rawText).joined(separator: "\n"))
            _result = State(initialValue: BatchAddResult(successCount: 5, failures: failures))
        } else {
            _text = State(initialValue: preview?.sampleText ?? "")
        }
    }

    private var validLineCount: Int {
        text
            // 与 prepareLines 同口径——CRLF 的 \r\n 是单个 Character，必须
            // whereSeparator 拆行，split(separator: "\n") 对 CRLF 文本整个不拆
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .count
    }
    private var isOverLimit: Bool { validLineCount > BatchAddParser.maxLines }

    var body: some View {
        // 与「修改事项」/主界面同一套材质：同一 VisualEffectView 经 ignoresSafeArea 铺满整窗
        ZStack {
            VisualEffectView()
                .ignoresSafeArea()

            ScrollView(.vertical) {
                contentBody
                    .frame(width: Self.contentWidth)
                    // 禁止 ScrollView 在内容高于视口时压缩内容：按自然高度布局，
                    // 展开瞬间不闪动、内边距不丢失（高度差由窗口顶部锚定长高吸收）
                    .fixedSize(horizontal: false, vertical: true)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: ContentHeightPreferenceKey.self,
                                value: proxy.size.height
                            )
                        }
                    )
            }
            .scrollDisabled(contentHeight <= Self.maxContentHeight)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onPreferenceChange(ContentHeightPreferenceKey.self) { height in
            guard abs(height - contentHeight) > 0.5 else { return }
            contentHeight = height
            onContentHeightChange?(height)
        }
    }

    private var contentBody: some View {
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

            moreOptions

            Divider()

            if let result {
                resultSummary(result)
            } else {
                actionBar
            }
        }
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
        // 编辑区取固定高度：TextEditor 自身滚动，窗口高度由「编辑区 + 底部区」的自然高度驱动
        .frame(height: Self.editorAreaHeight)
    }

    // MARK: - 更多选项（公共属性区：作用于全部行，控件与主输入面板同款）

    private var moreOptions: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Button 替代 DisclosureGroup：contentShape 让整行都是点击热区
            //（DisclosureGroup 只有 label 文本可点，热区偏小）
            Button {
                isMoreOptionsExpanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isMoreOptionsExpanded ? 90 : 0))
                    Text("更多选项")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                }
                .foregroundColor(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            if isMoreOptionsExpanded {
                commonAttributesForm
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
    }

    private var commonAttributesForm: some View {
        // 分组对齐 EditEventSheet：重复（周期/农历/限制有效期）/属性/提醒；
        // 批量提交固定不跳过节假日（需要时单条编辑开启）
        VStack(alignment: .leading, spacing: FormMetrics.sectionSpacing) {
            FormSection("重复") {
                FormRow("周期") {
                    RecurrencePickerView(
                        preset: $commonPreset,
                        spec: $commonSpec,
                        anchor: Date(),
                        isLunar: commonIsLunar
                    )
                }
                FormRow("农历") {
                    // 无规则（未选周期）时置灰，旁边给一句说明（不能切了无反应）
                    Toggle("", isOn: $commonIsLunar)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .formToggleSizing()
                        .disabled(!LunarMirrorPolicy.isLunarToggleEnabled(spec: commonSpec))
                }
                if let hint = RecurrencePickerView.lunarSystemHint(isLunar: commonIsLunar, spec: commonSpec) {
                    FormHint(hint)
                }
                FormRow("限制有效期") {
                    // 开启时开始端默认勾选且日期=当前时间、结束端不勾选（与主输入面板同款）
                    Toggle("", isOn: Binding(
                        get: { validityEnabled },
                        set: {
                            validityEnabled = $0
                            if $0 {
                                validityHasStart = true
                                validityStart = Date()
                                validityHasEnd = false
                            }
                        }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .formToggleSizing()
                }
                if validityEnabled {
                    FormRow("有效期起") {
                        HStack(spacing: 6) {
                            Toggle("", isOn: $validityHasStart)
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .formToggleSizing()
                            DatePicker("", selection: $validityStart, displayedComponents: [.date, .hourAndMinute])
                                .labelsHidden()
                                .disabled(!validityHasStart)
                                .formControlSizing()
                        }
                    }
                    FormRow("有效期止") {
                        HStack(spacing: 6) {
                            Toggle("", isOn: $validityHasEnd)
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .formToggleSizing()
                            DatePicker("", selection: $validityEnd, displayedComponents: [.date, .hourAndMinute])
                                .labelsHidden()
                                .disabled(!validityHasEnd)
                                .formControlSizing()
                        }
                    }
                    FormHint("有效期含起止端点，精确到时分（如 10:00 起、18:00 止）")
                }
            }
            FormSection("属性") {
                FormRow("颜色") {
                    FormColorSwatches(selection: $commonColor)
                }
                FormRow("优先级") {
                    FormPriorityPicker(selection: $commonPriority)
                }
            }
            FormSection("提醒") {
                FormRow("提前提醒") {
                    ReminderLeadPickerView(offsets: $commonOffsets)
                }
                FormRow("添加到提醒") {
                    Toggle("", isOn: $createAsReminder)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .formToggleSizing()
                }
            }
        }
        .padding(.horizontal, 6)
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

        // 公共属性快照：提交瞬间取值，避免提交中改状态影响本批
        let common = BatchAddCommonAttributes(
            color: commonColor,
            priority: commonPriority,
            spec: commonSpec,
            isLunar: commonIsLunar,
            reminderOffsets: commonOffsets.isEmpty ? nil : commonOffsets
        )
        // 有效期组装：开关关 = nil 不限制；开 = 按两端勾选组装（与主输入面板同口径）
        let validity: ValidityPeriod? = validityEnabled ? ValidityPeriod(
            start: validityHasStart ? validityStart : nil,
            end: validityHasEnd ? validityEnd : nil
        ) : nil

        Task { @MainActor in
            var successCount = 0
            var failures: [BatchAddFailure] = []
            for line in lines {
                do {
                    // 行内 NLP 解析出的字段优先，公共值兜底（含 isLunar OR 合并）
                    let resolved = common.resolving(line.parsed)
                    try calendarService.createEvent(
                        title: line.parsed.title,
                        startDate: line.parsed.date,
                        endDate: line.parsed.date.addingTimeInterval(3600),  // 非全天默认结束 = 开始 +1h
                        isAllDay: false,                                     // 批量无全天开关，不隐式判全天
                        calendar: nil,
                        priority: resolved.priority == .none ? nil : resolved.priority,
                        recurrence: nil,
                        recurrenceSpec: resolved.spec,                       // nil 时 createEvent 按 1 次推导
                        reminderOffsets: resolved.reminderOffsets,           // nil = 无提前提醒
                        category: .user,
                        asReminder: createAsReminder,
                        isLunar: resolved.isLunar,
                        color: resolved.color,
                        skipHolidays: false,  // 批量固定不跳过节假日（开关已移除，需要时单条编辑开启）
                        validity: validity
                    )
                    successCount += 1
                } catch {
                    AppLogger.ui.error("批量添加失败: \(String(describing: error))")
                    failures.append(BatchAddFailure(rawText: line.rawText, reason: "写入日历失败"))
                }
                // createEvent 为 @MainActor 同步
                // EK 写 + 缓存写，最多 100 次循环独占主线程冻结 UI；每条让出一轮
                // runloop，isProcessing 动画与交互可穿插响应（总量不变，消除冻结）
                await Task.yield()
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
