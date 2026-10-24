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
    @State private var taskReminderMinutes: Int = 10
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
    }

    // MARK: - 属性编辑器
    // 栅格化三分组（时间/属性/提醒）：标签列对齐、控件原生尺寸（不再 scaleEffect 缩放）

    private var attributeEditor: some View {
        // 表单内滚动：布局锁定后仅当表单超出剩余空间时滚动，日历/工具栏不被挤压
        ScrollView(.vertical) {
            attributeEditorContent
        }
    }

    private var attributeEditorContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            // 标题预览：与栅格标签列对齐
            HStack(spacing: 8) {
                GridLabel("标题")
                Text(taskTitle.isEmpty ? "待办事项" : taskTitle)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            AttributeGroup("时间") {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        GridLabel("日期时间")
                        DatePicker(
                            "",
                            selection: Binding(
                                get: { taskDate },
                                set: { taskDate = $0; manuallyEditedDate = true }  // V-7：手选日期不被 NLP 覆盖
                            ),
                            displayedComponents: taskIsAllDay ? [.date] : [.date, .hourAndMinute]
                        )
                        .labelsHidden()
                        .gridCellColumns(3)
                    }
                    GridRow {
                        GridLabel("全天")
                        // V-16：显式"全天"开关替代时分==0 隐式推断，用户可控可感知
                        Toggle("", isOn: $taskIsAllDay)
                            .toggleStyle(.switch)
                            .labelsHidden()
                        GridLabel("农历")
                        Toggle("", isOn: Binding(
                            get: { taskIsLunar },
                            set: { taskIsLunar = $0; manuallyEditedLunar = true }  // V-7：手选开关不被 NLP 覆盖
                        ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }
            }

            Divider()

            // 循环语义集中一处：周期/跳过节假日/限制有效期同属「重复」组（spec 定案）
            AttributeGroup("重复") {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        GridLabel("周期")
                        Picker("", selection: Binding(
                            get: { taskRecurrence },
                            set: { taskRecurrence = $0; manuallyEditedRecurrence = true }  // V-7：手选周期不被 NLP 覆盖
                        )) {
                            Text("1次").tag(RecurrenceType.none)
                            Text("不限").tag(RecurrenceType.unlimited)
                            Text("每天").tag(RecurrenceType.daily)
                            Text("每周").tag(RecurrenceType.weekly)
                            Text("每月").tag(RecurrenceType.monthly)
                            Text("每年").tag(RecurrenceType.yearly)
                        }
                        .labelsHidden()
                        .frame(width: 70)
                    }
                    GridRow {
                        GridLabel("跳过节假日")
                        // AC-7：勾选后 startDate 落休日顺延至下一个班日显示与提醒
                        Toggle("", isOn: $taskSkipHolidays)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                    GridRow {
                        GridLabel("限制有效期")
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
                    }
                    if taskValidityEnabled {
                        GridRow {
                            GridLabel("开始")
                            Toggle("", isOn: $taskValidityHasStart)
                                .toggleStyle(.switch)
                                .labelsHidden()
                            DatePicker("", selection: $taskValidityStart, displayedComponents: [.date])
                                .labelsHidden()
                                .disabled(!taskValidityHasStart)
                        }
                        GridRow {
                            GridLabel("结束")
                            Toggle("", isOn: $taskValidityHasEnd)
                                .toggleStyle(.switch)
                                .labelsHidden()
                            DatePicker("", selection: $taskValidityEnd, displayedComponents: [.date])
                                .labelsHidden()
                                .disabled(!taskValidityHasEnd)
                        }
                    }
                }
            }

            Divider()

            AttributeGroup("属性") {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        GridLabel("颜色")
                        HStack(spacing: 6) {
                            ForEach(EventColor.allCases, id: \.self) { color in
                                Circle()
                                    .fill(Color(hex: color.rawValue))
                                    .frame(width: 14, height: 14)
                                    .overlay(
                                        Circle().stroke(taskColor == color ? Color.primary : Color.clear, lineWidth: 1.5)
                                    )
                                    .onTapGesture {
                                        taskColor = taskColor == color ? nil : color
                                        manuallyEditedColor = true  // V-7：手选颜色不被 NLP 覆盖
                                    }
                            }
                        }
                        .gridCellColumns(3)
                    }
                    GridRow {
                        GridLabel("优先级")
                        Picker("", selection: Binding(
                            get: { taskPriority },
                            set: { taskPriority = $0; manuallyEditedPriority = true }  // V-7：手选优先级不被 NLP 覆盖
                        )) {
                            ForEach(EventPriority.allCases, id: \.self) { p in
                                Text(p.displayName).tag(p)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 70)
                    }
                }
            }

            Divider()

            AttributeGroup("提醒") {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        GridLabel("提醒")
                        Picker("", selection: Binding(
                            get: { taskReminderMinutes },
                            set: { taskReminderMinutes = $0; manuallyEditedReminder = true }  // V-7：手选提醒不被 NLP 覆盖
                        )) {
                            Text("不提醒").tag(0)
                            Text("5分钟前").tag(5)
                            Text("10分钟前").tag(10)
                            Text("30分钟前").tag(30)
                            Text("1小时前").tag(60)
                            Text("1天前").tag(1440)
                        }
                        .labelsHidden()
                        .frame(width: 90)
                        GridLabel("添加到提醒")
                        Toggle("", isOn: $createAsReminder)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }
            }
        }
        .padding(.horizontal, 8)
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
        if !manuallyEditedRecurrence { taskRecurrence = parsed.recurrence ?? .none }
        if !manuallyEditedReminder { taskReminderMinutes = parsed.reminderMinutes ?? 10 }
        if !manuallyEditedLunar { taskIsLunar = parsed.isLunar }
    }

    private func addTask() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }

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
                    reminderMinutes: taskReminderMinutes > 0 ? taskReminderMinutes : nil,
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
        taskReminderMinutes = 10
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

// MARK: - 栅格化私有组件

/// 栅格标签：右对齐保证同列标签对齐，minWidth 保证 2~4 字标签间距一致
private struct GridLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .frame(minWidth: 44, alignment: .trailing)
    }
}

/// 属性小节分组：小节标题 + 内容（组间由 Divider 分隔）
private struct AttributeGroup<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
            content
        }
    }
}
