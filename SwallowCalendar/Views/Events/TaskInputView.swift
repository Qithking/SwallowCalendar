//
//  TaskInputView.swift
//  SwallowCalendar
//

import SwiftUI

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
    @State private var accentColor: Color = Color(hex: AppSettings.shared.accentColorHex)

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: "plus.circle.fill")
                    .foregroundColor(accentColor)
                    .font(.system(size: 14))

                TextField("输入待办，如：明天下午3点开会 红色 重要 每天循环", text: $inputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit {
                        addTask()
                    }
                    .onChange(of: inputText) { _, newValue in
                        updateFromNLP(newValue)
                        if !newValue.isEmpty {
                            showAttributeEditor = true
                        }
                    }

                if !inputText.isEmpty {
                    Button {
                        showAttributeEditor.toggle()
                    } label: {
                        Image(systemName: showAttributeEditor ? "slider.horizontal.3" : "slider.horizontal.3")
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
                            .foregroundColor(accentColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(isProcessing)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .stroke(accentColor.opacity(0.3), lineWidth: 1)
            )

            // 属性编辑面板
            if showAttributeEditor && !inputText.isEmpty {
                attributeEditor
            }
        }
        .onChange(of: appSettings.accentColorHex) { _, newColor in
            accentColor = Color(hex: newColor)
        }
    }

    // MARK: - 属性编辑器

    private var attributeEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            // 第一行：标题预览 + 日期时间
            HStack(spacing: 8) {
                Text(taskTitle.isEmpty ? "待办事项" : taskTitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Spacer()

                DatePicker("", selection: $taskDate, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .scaleEffect(0.8)
            }

            // 第二行：农历开关 + 颜色选择
            HStack(spacing: 12) {
                Toggle("农历", isOn: $taskIsLunar)
                    .toggleStyle(.switch)
                    .scaleEffect(0.75)

                Divider().frame(height: 16)

                // 颜色选择
                HStack(spacing: 4) {
                    Text("颜色:")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    ForEach(EventColor.allCases, id: \.self) { color in
                        Circle()
                            .fill(Color(hex: color.rawValue))
                            .frame(width: 14, height: 14)
                            .overlay(
                                Circle().stroke(taskColor == color ? Color.primary : Color.clear, lineWidth: 1)
                            )
                            .onTapGesture {
                                taskColor = taskColor == color ? nil : color
                            }
                    }
                }

                Spacer()
            }

            // 第三行：优先级 + 周期
            HStack(spacing: 12) {
                // 优先级
                HStack(spacing: 4) {
                    Text("优先级:")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Picker("", selection: $taskPriority) {
                        ForEach(EventPriority.allCases, id: \.self) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    .labelsHidden()
                    .scaleEffect(0.75)
                }

                Divider().frame(height: 16)

                // 周期
                HStack(spacing: 4) {
                    Text("周期:")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Picker("", selection: $taskRecurrence) {
                        Text("1次").tag(RecurrenceType.none)
                        Text("不限").tag(RecurrenceType.daily)
                        Text("每天").tag(RecurrenceType.daily)
                        Text("每周").tag(RecurrenceType.weekly)
                        Text("每月").tag(RecurrenceType.monthly)
                        Text("每年").tag(RecurrenceType.yearly)
                    }
                    .labelsHidden()
                    .scaleEffect(0.75)
                }

                Spacer()
            }

            // 第四行：提醒时间
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Text("提醒:")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Picker("", selection: $taskReminderMinutes) {
                        Text("不提醒").tag(0)
                        Text("5分钟前").tag(5)
                        Text("10分钟前").tag(10)
                        Text("30分钟前").tag(30)
                        Text("1小时前").tag(60)
                        Text("1天前").tag(1440)
                    }
                    .labelsHidden()
                    .scaleEffect(0.75)
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
        taskDate = parsed.date
        taskColor = parsed.color
        taskPriority = parsed.priority ?? .none
        taskRecurrence = parsed.recurrence ?? .none
        taskReminderMinutes = parsed.reminderMinutes ?? 10
        taskIsLunar = parsed.isLunar
    }

    private func addTask() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }

        isProcessing = true
        print("[TaskInput] 添加任务: title=\(taskTitle.isEmpty ? "待办事项" : taskTitle), date=\(taskDate), reminder=\(taskReminderMinutes)分钟")

        let isAllDay = Calendar.current.component(.hour, from: taskDate) == 0
            && Calendar.current.component(.minute, from: taskDate) == 0

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
                    reminderMinutes: taskReminderMinutes > 0 ? taskReminderMinutes : nil
                )
                await MainActor.run {
                    inputText = ""
                    resetTaskAttributes()
                    refreshTrigger.toggle()  // 触发视图刷新
                    onTaskAdded?()
                }
                print("[TaskInput] 任务添加成功")
            } catch {
                print("[TaskInput] 任务添加失败: \(error)")
            }
            await MainActor.run {
                isProcessing = false
            }
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
        showAttributeEditor = false
    }

}
