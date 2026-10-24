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

    private var attributeEditor: some View {
        VStack(spacing: 8) {
            Divider()

            // 第一行：标题预览 + 日期时间
            HStack {
                Text(taskTitle.isEmpty ? "待办事项" : taskTitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Spacer()

                // V-16：显式"全天"开关替代时分==0 隐式推断，用户可控可感知
                HStack(spacing: 2) {
                    Text("全天")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Toggle("", isOn: $taskIsAllDay)
                        .toggleStyle(.switch)
                        .scaleEffect(0.6)
                        .labelsHidden()
                }
                DatePicker(
                    "",
                    selection: Binding(
                        get: { taskDate },
                        set: { taskDate = $0; manuallyEditedDate = true }  // V-7：手选日期不被 NLP 覆盖
                    ),
                    displayedComponents: taskIsAllDay ? [.date] : [.date, .hourAndMinute]
                )
                .labelsHidden()
                .scaleEffect(0.8)
            }

            // 第二行：农历开关 + 颜色选择
            HStack {
                // 左侧：农历开关
                HStack(spacing: 4) {
                    Text("农历")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Toggle("", isOn: Binding(
                        get: { taskIsLunar },
                        set: { taskIsLunar = $0; manuallyEditedLunar = true }  // V-7：手选开关不被 NLP 覆盖
                    ))
                        .toggleStyle(.switch)
                        .scaleEffect(0.65)
                }

                Spacer()

                // 右侧：颜色选择
                HStack(spacing: 3) {
                    ForEach(EventColor.allCases, id: \.self) { color in
                        Circle()
                            .fill(Color(hex: color.rawValue))
                            .frame(width: 16, height: 16)
                            .overlay(
                                Circle().stroke(taskColor == color ? Color.primary : Color.clear, lineWidth: 1.5)
                            )
                            .onTapGesture {
                                taskColor = taskColor == color ? nil : color
                                manuallyEditedColor = true  // V-7：手选颜色不被 NLP 覆盖
                            }
                    }
                }
            }

            // 第三行：优先级 + 周期
            HStack {
                // 左侧：优先级
                HStack(spacing: 4) {
                    Text("优先级")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Picker("", selection: Binding(
                        get: { taskPriority },
                        set: { taskPriority = $0; manuallyEditedPriority = true }  // V-7：手选优先级不被 NLP 覆盖
                    )) {
                        ForEach(EventPriority.allCases, id: \.self) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    .labelsHidden()
                    .scaleEffect(0.75)
                    .frame(width: 80)
                }

                Spacer()

                // 右侧：周期
                HStack(spacing: 4) {
                    Text("周期")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
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
                    .scaleEffect(0.75)
                    .frame(width: 80)
                }
            }

            // 第四行：提醒时间 + 创建为提醒开关
            HStack {
                // 左侧：提醒时间
                HStack(spacing: 4) {
                    Text("提醒")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
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
                    .scaleEffect(0.75)
                    .frame(width: 110)
                }
                
                Spacer()
                
                // 右侧：创建为系统提醒开关
                HStack(spacing: 4) {
                    Text("添加到提醒")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Toggle("", isOn: $createAsReminder)
                        .toggleStyle(.switch)
                        .scaleEffect(0.65)
                }
            }

            // 第五行：智能跳过节假日开关（AC-7；勾选后按日历休/班标识顺延显示与提醒）
            HStack {
                HStack(spacing: 4) {
                    Text("跳过节假日")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Toggle("", isOn: $taskSkipHolidays)
                        .toggleStyle(.switch)
                        .scaleEffect(0.65)
                }
                Spacer()
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
                    skipHolidays: taskSkipHolidays
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
        showAttributeEditor = false
        // V-7：重置手动修改标记，下一条任务的 NLP 解析恢复全字段覆盖
        manuallyEditedDate = false
        manuallyEditedColor = false
        manuallyEditedPriority = false
        manuallyEditedRecurrence = false
        manuallyEditedReminder = false
        manuallyEditedLunar = false
    }

}
