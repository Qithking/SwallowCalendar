//
//  TaskInputView.swift
//  SwallowCalendar
//

import SwiftUI
import os

struct TaskInputView: View {
    @Environment(AppSettings.self) private var appSettings
    let calendarService: CalendarService
    let calendarPreferences: [CalendarPreference]
    @Binding var refreshTrigger: Bool
    // 编辑属性态联动：面板显示 ⇔ 编辑态，父视图据此隐藏筛选条与待办/已办列表模块
    @Binding var isEditingAttributes: Bool
    var onTaskAdded: (() -> Void)?

    @State private var inputText = ""
    @State private var isProcessing = false
    // 可编辑的任务属性
    @State private var taskTitle = ""
    @State private var taskDate = Date()
    @State private var taskColor: EventColor?
    @State private var taskPriority: EventPriority = .none
    @State private var taskRecurrence: RecurrenceType = .none
    /// 循环规则单一真源（12 项预设 + 自定义维度）
    @State private var taskPreset: RecurrencePreset = .never
    @State private var taskSpec: RecurrenceSpec?
    /// 提前提醒档位（有符号分钟：正=提前、0=到点、负=延后；空=无提前提醒）
    @State private var taskReminderOffsets: [Int] = []
    @State private var taskIsLunar = false
    @State private var showAttributeEditor = false
    // V-7：用户手动修改过的属性标记——NLP 解析只覆盖未手动修改的字段，避免覆盖用户手选值
    @State private var manuallyEditedDate = false
    @State private var manuallyEditedColor = false
    @State private var manuallyEditedPriority = false
    @State private var manuallyEditedRecurrence = false
    @State private var manuallyEditedReminder = false
    @State private var manuallyEditedLunar = false
    @State private var createAsReminder = false  // 是否创建为系统提醒
    // V-16：全天由用户显式控制，NLP"明天"解析为 00:00 不再被隐式误判为全天
    @State private var taskIsAllDay = false
    // 智能跳过节假日（AC-7）：勾选后 startDate 落休日顺延至下一个班日显示与提醒
    @State private var taskSkipHolidays = false
    // 任务有效期（spec/task-validity-period）：总开关默认关；开启后开始端默认勾选=任务日期、结束端不勾选
    @State private var taskValidityEnabled = false
    @State private var taskValidityHasStart = true
    @State private var taskValidityHasEnd = false
    @State private var taskValidityStart = Date()
    @State private var taskValidityEnd = Date()
    @State private var nlpTask: Task<Void, Never>?

    // V-18：直接读 appSettings 主题色，替代 @State 复制 + onChange 同步
    private var themeAccent: Color { Color(hex: appSettings.accentColorHex) }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: "plus.circle.fill")
                    .foregroundColor(themeAccent)
                    .font(.system(size: 14))

                TextField("输入待办，如：明天下午3点开会 红色 重要 每天循环", text: $inputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit {
                        addTask()
                    }
                    .onChange(of: inputText) { _, newValue in
                        // 防抖：取消之前的 NLP 解析任务
                        nlpTask?.cancel()
                        if !newValue.isEmpty {
                            showAttributeEditor = true
                            nlpTask = Task {
                                // 等待 200ms，如果用户继续输入则取消
                                try? await Task.sleep(nanoseconds: 200_000_000)
                                guard !Task.isCancelled else { return }
                                updateFromNLP(newValue)
                            }
                        } else {
                            // bug: task-input-clear-attribute-leak——清空输入不提交时，
                            // 上次编辑的属性与 manuallyEdited 标记残留泄漏到下一条任务
                            // （V-7 标记残留使 NLP 不覆盖用户上次手选字段）；
                            // 提交路径复位在 addTask→resetTaskAttributes，此处为清空路径对称复位
                            resetTaskAttributes()
                        }
                        // 联动父视图编辑态：面板显示 ⇔ 编辑态（清空输入即退出编辑态）
                        isEditingAttributes = showAttributeEditor && !newValue.isEmpty
                    }

                // 批量添加入口：打开独立弹窗，多行输入每行一条（spec: batch-add-events）
                Button {
                    BatchAddWindowManager.shared.open(
                        calendarService: calendarService,
                        appSettings: appSettings,
                        onTaskAdded: { onTaskAdded?() }
                    )
                } label: {
                    // 图标须用本机 SF Symbols 名单存在的名称，无效名称会渲染空白导致按钮不可见
                    Image(systemName: "plus.square.on.square")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("批量添加")

                if !inputText.isEmpty {
                    Button {
                        showAttributeEditor.toggle()
                        // 手动开合面板时同步父视图编辑态
                        isEditingAttributes = showAttributeEditor && !inputText.isEmpty
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("编辑属性")

                    Button {
                        addTask()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(themeAccent)
                    }
                    .buttonStyle(.plain)
                    .disabled(isProcessing)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.clear)
                    .stroke(themeAccent.opacity(0.3), lineWidth: 1)
            )

            // 属性编辑面板
            if showAttributeEditor && !inputText.isEmpty {
                attributeEditor
            }
        }
        .onDisappear {
            // V-15：面板关闭时取消残留的 NLP 防抖任务——200ms 后解析仍会
            // 执行一次并覆盖已重置的状态
            nlpTask?.cancel()
        }
        .onAppear {
            // 调试取证入口（SC_OPEN_TASK_EDITOR_PREVIEW=1）：直接展开新建表单，
            // 供截图核对四张卡片等宽与各行右基准；正常启动不生效
            guard ProcessInfo.processInfo.environment["SC_OPEN_TASK_EDITOR_PREVIEW"] == "1",
                  inputText.isEmpty else { return }
            inputText = "示例待办"
            showAttributeEditor = true
            isEditingAttributes = true
            if ProcessInfo.processInfo.environment["SC_TASK_PREVIEW_VALIDITY"] == "1" {
                taskValidityEnabled = true
                taskValidityHasStart = true
                taskValidityHasEnd = true
            }
        }
    }

    // MARK: - 属性编辑器
    // 与编辑表单共用 FormSection/FormRow：标签左对齐固定列宽，控件起点与间距统一

    private var attributeEditor: some View {
        // 表单内滚动：布局锁定后仅当表单超出剩余空间时滚动，日历/工具栏不被挤压
        ScrollView(.vertical) {
            attributeEditorContent
        }
    }

    private var attributeEditorContent: some View {
        VStack(alignment: .leading, spacing: FormMetrics.sectionSpacing) {
            FormSection("基本") {
                VStack(alignment: .leading, spacing: FormMetrics.rowSpacing) {
                    FormRow("标题") {
                        Text(taskTitle.isEmpty ? "待办事项" : taskTitle)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    FormRow("日期时间") {
                        DatePicker(
                            "",
                            selection: Binding(
                                get: { taskDate },
                                set: { taskDate = $0; manuallyEditedDate = true }  // V-7：手选日期不被 NLP 覆盖
                            ),
                            displayedComponents: taskIsAllDay ? [.date] : [.date, .hourAndMinute]
                        )
                        .labelsHidden()
                        // 固有宽度 + FormRow 的 trailing 容器：右边缘与「全天」开关共线
                        .formControlSizing()
                    }
                    FormRow("全天") {
                        // V-16：显式"全天"开关替代时分==0 隐式推断，用户可控可感知
                        Toggle("", isOn: $taskIsAllDay)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .formToggleSizing()
                    }
                    FormRow("农历") {
                        Toggle("", isOn: Binding(
                            get: { taskIsLunar },
                            set: { taskIsLunar = $0; manuallyEditedLunar = true }  // V-7：手选开关不被 NLP 覆盖
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .formToggleSizing()
                        // 无规则/单期时置灰，旁边给一句说明（不能切了无反应）
                        .disabled(!LunarMirrorPolicy.isLunarToggleEnabled(spec: taskSpec))
                    }
                    if let hint = RecurrencePickerView.lunarSystemHint(isLunar: taskIsLunar, spec: taskSpec) {
                        FormHint(hint)
                    }
                }
            }

            // 循环语义集中一处：周期/跳过节假日/限制有效期同属「重复」组（spec 定案）
            FormSection("重复") {
                VStack(alignment: .leading, spacing: FormMetrics.rowSpacing) {
                    FormRow("周期") {
                        RecurrencePickerView(
                            preset: Binding(
                                get: { taskPreset },
                                // V-7：手选周期不被 NLP 覆盖
                                set: { taskPreset = $0; manuallyEditedRecurrence = true }
                            ),
                            spec: Binding(
                                get: { taskSpec },
                                set: { taskSpec = $0; taskRecurrence = $0?.legacyType ?? .none }
                            ),
                            anchor: taskDate,
                            isLunar: taskIsLunar
                        )
                    }
                    FormRow("限制有效期") {
                        // spec/task-validity-period：开启时开始端默认勾选且日期=当前任务日期、结束端不勾选
                        Toggle("", isOn: Binding(
                            get: { taskValidityEnabled },
                            set: {
                                taskValidityEnabled = $0
                                if $0 {
                                    taskValidityHasStart = true
                                    taskValidityStart = taskDate
                                    taskValidityHasEnd = false
                                }
                            }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .formToggleSizing()
                    }
                    if taskValidityEnabled {
                        FormRow("有效期起") {
                            HStack(spacing: 6) {
                                Toggle("", isOn: $taskValidityHasStart)
                                    .toggleStyle(.switch)
                                    .labelsHidden()
                                    .formToggleSizing()
                                DatePicker("", selection: $taskValidityStart, displayedComponents: [.date, .hourAndMinute])
                                    .labelsHidden()
                                    .disabled(!taskValidityHasStart)
                                    // 固有宽度：整行由 FormRow 右贴，日期右缘（箭头）落在统一基准线
                                    .formControlSizing()
                            }
                        }
                        FormRow("有效期止") {
                            HStack(spacing: 6) {
                                Toggle("", isOn: $taskValidityHasEnd)
                                    .toggleStyle(.switch)
                                    .labelsHidden()
                                    .formToggleSizing()
                                DatePicker("", selection: $taskValidityEnd, displayedComponents: [.date, .hourAndMinute])
                                    .labelsHidden()
                                    .disabled(!taskValidityHasEnd)
                                    .formControlSizing()
                            }
                        }
                        FormHint("有效期含起止端点，精确到时分（如 10:00 起、18:00 止）")
                    }
                }
            }

            FormSection("属性") {
                VStack(alignment: .leading, spacing: FormMetrics.rowSpacing) {
                    FormRow("颜色") {
                        FormColorSwatches(selection: Binding(
                            get: { taskColor },
                            set: { taskColor = $0; manuallyEditedColor = true }  // V-7：手选颜色不被 NLP 覆盖
                        ))
                    }
                    FormRow("优先级") {
                        FormPriorityPicker(selection: Binding(
                            get: { taskPriority },
                            set: { taskPriority = $0; manuallyEditedPriority = true }  // V-7：手选优先级不被 NLP 覆盖
                        ))
                    }
                }
            }

            FormSection("提醒") {
                VStack(alignment: .leading, spacing: FormMetrics.rowSpacing) {
                    FormRow("提前提醒") {
                        ReminderLeadPickerView(
                            offsets: Binding(
                                get: { taskReminderOffsets },
                                set: { taskReminderOffsets = $0; manuallyEditedReminder = true }  // V-7：手选提醒不被 NLP 覆盖
                            )
                        )
                    }
                    FormRow("添加到提醒") {
                        Toggle("", isOn: $createAsReminder)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .formToggleSizing()
                    }
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private func updateFromNLP(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            return
        }
        let parsed = NLPTaskParser.parse(text)
        taskTitle = parsed.title
        // V-7：仅覆盖用户未手动修改的字段，手选值不被 NLP 解析结果覆盖
        if !manuallyEditedDate { taskDate = parsed.date }
        if !manuallyEditedColor { taskColor = parsed.color }
        if !manuallyEditedPriority { taskPriority = parsed.priority ?? .none }
        if !manuallyEditedRecurrence {
            taskRecurrence = parsed.recurrence ?? .none
            taskPreset = RecurrencePreset.legacy(parsed.recurrence ?? .none)
            taskSpec = RecurrenceSpec.legacy(from: parsed.recurrence ?? .none, anchor: taskDate, isLunar: parsed.isLunar)
            // 解析出每小时/工作日等细分档位时，界面精确对齐细分预设
            if let spec = taskSpec {
                taskPreset = RecurrenceSpec.preset(for: spec, anchor: taskDate)
            }
        }
        if !manuallyEditedReminder {
            if let minutes = parsed.reminderMinutes, minutes > 0 {
                taskReminderOffsets = [minutes]
            } else {
                taskReminderOffsets = []
            }
        }
        if !manuallyEditedLunar { taskIsLunar = parsed.isLunar }
    }

    private func addTask() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }

        // R-8：冲刷 200ms NLP 防抖——输入后 200ms 内回车时防抖任务尚未执行，
        // taskTitle 仍是旧值/空值，落库「待办事项」且用户文本被清空丢弃。
        // 取消挂起任务并按当前输入框文本同步重解析（V-7 手动修改标记仍生效）
        nlpTask?.cancel()
        updateFromNLP(inputText)

        isProcessing = true

        // V-16：全天由用户开关决定——原"时分均为 0"推断会把 NLP 解析的
        // "明天"（00:00）误判为全天事件，用户无感知
        let isAllDay = taskIsAllDay

        // 有效期组装（spec AC-6，plan step 11）：开关关 = nil 不限制；开 = 按两端勾选组装
        // （归一化落库由 createEvent 内完成）
        let validity: ValidityPeriod? = taskValidityEnabled ? ValidityPeriod(
            start: taskValidityHasStart ? taskValidityStart : nil,
            end: taskValidityHasEnd ? taskValidityEnd : nil
        ) : nil

        Task { @MainActor in
            do {
                try calendarService.createEvent(
                    title: taskTitle.isEmpty ? "待办事项" : taskTitle,
                    startDate: taskDate,
                    endDate: isAllDay ? nil : taskDate.addingTimeInterval(3600),
                    isAllDay: isAllDay,
                    calendar: nil,
                    priority: taskPriority == .none ? nil : taskPriority,
                    recurrence: taskRecurrence,
                    recurrenceSpec: taskSpec,
                    reminderOffsets: taskReminderOffsets.isEmpty ? nil : taskReminderOffsets,
                    category: .user,
                    asReminder: createAsReminder,
                    isLunar: taskIsLunar,
                    color: taskColor,
                    skipHolidays: taskSkipHolidays,
                    validity: validity
                )
                inputText = ""
                resetTaskAttributes()
                onTaskAdded?()
            } catch {
                AppLogger.ui.error("任务添加失败: \(String(describing: error))")
            }
            isProcessing = false
        }
    }

    private func resetTaskAttributes() {
        taskTitle = ""
        taskDate = Date()
        taskColor = nil
        taskPriority = .none
        taskRecurrence = .none
        taskPreset = .never
        taskSpec = nil
        taskReminderOffsets = []
        taskIsLunar = false
        taskIsAllDay = false
        createAsReminder = false
        taskSkipHolidays = false
        // 有效期复位：总开关关 + 默认两端勾选态（spec Assumption：开=开始勾选/结束不勾选）
        taskValidityEnabled = false
        taskValidityHasStart = true
        taskValidityHasEnd = false
        taskValidityStart = Date()
        taskValidityEnd = Date()
        showAttributeEditor = false
        // 同步父视图编辑态：提交/重置后恢复下方模块显示
        isEditingAttributes = false
        // V-7：重置手动修改标记，下一条任务的 NLP 解析恢复全字段覆盖
        manuallyEditedDate = false
        manuallyEditedColor = false
        manuallyEditedPriority = false
        manuallyEditedRecurrence = false
        manuallyEditedReminder = false
        manuallyEditedLunar = false
    }

}
