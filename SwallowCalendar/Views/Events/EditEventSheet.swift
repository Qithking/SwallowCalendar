//
//  EditEventSheet.swift
//  SwallowCalendar
//

import SwiftUI
import SwiftData
import AppKit
import os

struct EditEventSheet: View {
    let event: CalendarEvent
    let calendarService: CalendarService
    var onDismiss: (() -> Void)?
    var onSave: (() -> Void)? = nil  // 保存成功通知回调

    @State private var title: String
    @State private var startDate: Date
    @State private var isAllDay: Bool
    @State private var taskColor: EventColor?
    @State private var taskPriority: EventPriority = .none
    @State private var taskRecurrence: RecurrenceType = .none
    @State private var taskReminderOffsets: [Int] = []
    @State private var showCustomReminderInput: Bool = false
    @State private var customReminderText: String = ""
    @State private var isProcessing = false
    
    // 保存原始周期类型，用于检测变更
    private let originalRecurrence: RecurrenceType

    init(event: CalendarEvent, calendarService: CalendarService, onDismiss: (() -> Void)? = nil, onSave: (() -> Void)? = nil) {
        self.event = event
        self.calendarService = calendarService
        self.onDismiss = onDismiss
        self.onSave = onSave
        _title = State(initialValue: event.title)
        _startDate = State(initialValue: event.startDate ?? Date())
        _isAllDay = State(initialValue: event.isAllDay)
        
        // 获取原始周期类型（需要从缓存中读取）
        let context = EventCacheService.shared.context
        var originalRec = RecurrenceType.none
        if let context = context {
            let targetID = event.id
            var descriptor = FetchDescriptor<CachedEvent>(
                predicate: #Predicate { $0.eventID == targetID }
            )
            descriptor.fetchLimit = 1
            if let cached = try? context.fetch(descriptor).first {
                originalRec = cached.recurrenceType
                _taskRecurrence = State(initialValue: cached.recurrenceType)
                _taskPriority = State(initialValue: EventPriority(rawValue: cached.priority) ?? .none)
                // 多级提醒 chips 初始选中：过滤 0 档（0 = 不提醒，即无选中态）
                _taskReminderOffsets = State(initialValue: cached.reminderOffsets.filter { $0 > 0 })
                if let hex = cached.eventColorHex {
                    _taskColor = State(initialValue: EventColor(rawValue: hex))
                }
            }
        }
        self.originalRecurrence = originalRec
    }

    var body: some View {
        VStack(spacing: 12) {
            // 顶部标题栏：事件日历色点 + 标题 + 取消（Esc）
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(hex: event.eventColorHex ?? event.calendarColorHex))
                    .frame(width: 4, height: 16)
                Text("修改事件")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("取消") {
                    onDismiss?()
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .keyboardShortcut(.cancelAction)
            }

            // 分组卡片：基本信息
            FormCard(title: "基本信息") {
                // 标题输入（多行 textarea 风格）：TextEditor 无原生 placeholder，空内容时叠加提示文字
                ZStack(alignment: .topLeading) {
                    if title.isEmpty {
                        Text("事件标题")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary.opacity(0.5))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $title)
                        .font(.system(size: 13))
                        .frame(height: 64)
                        .padding(2)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                )

                FormRow(label: "全天") {
                    Toggle("", isOn: $isAllDay)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                FormRow(label: "日期") {
                    DatePicker("", selection: $startDate, displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute])
                        .labelsHidden()
                }
            }

            // 分组卡片：属性
            FormCard(title: "属性") {
                FormRow(label: "颜色") {
                    HStack(spacing: 8) {
                        ForEach(EventColor.allCases, id: \.self) { color in
                            Button {
                                taskColor = taskColor == color ? nil : color
                            } label: {
                                Circle()
                                    .fill(Color(hex: color.rawValue))
                                    .frame(width: 18, height: 18)
                                    .overlay(
                                        // 选中态：外圈描边环；未选中无描边
                                        Circle()
                                            .strokeBorder(Color.primary.opacity(0.85), lineWidth: 1.5)
                                            .frame(width: 24, height: 24)
                                            .opacity(taskColor == color ? 1 : 0)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                FormRow(label: "优先级") {
                    Picker("", selection: $taskPriority) {
                        ForEach(EventPriority.allCases, id: \.self) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }

                FormRow(label: "周期") {
                    Picker("", selection: $taskRecurrence) {
                        Text("1次").tag(RecurrenceType.none)
                        Text("每天").tag(RecurrenceType.daily)
                        Text("每周").tag(RecurrenceType.weekly)
                        Text("每月").tag(RecurrenceType.monthly)
                        Text("每年").tag(RecurrenceType.yearly)
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }

                // 多级提醒 chips（G5 档位上限 1440 分钟；全部取消 = 不提醒）
                FormRow(label: "提醒") {
                    VStack(alignment: .trailing, spacing: 5) {
                        // 第一行：预设档位
                        HStack(spacing: 4) {
                            ForEach([5, 10, 30, 60, 1440], id: \.self) { minutes in
                                ReminderChip(
                                    label: Self.chipLabel(for: minutes),
                                    isOn: taskReminderOffsets.contains(minutes)
                                ) {
                                    if let idx = taskReminderOffsets.firstIndex(of: minutes) {
                                        taskReminderOffsets.remove(at: idx)
                                    } else {
                                        taskReminderOffsets.append(minutes)
                                    }
                                }
                            }
                            // 自定义档入口
                            Button {
                                showCustomReminderInput.toggle()
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 10, weight: .medium))
                                    .frame(width: 20, height: 18)
                            }
                            .buttonStyle(.plain)
                            .help("添加自定义提前分钟数（不超过 1440）")
                        }
                        // 第二行：自定义档输入（点 + 出现）
                        if showCustomReminderInput {
                            HStack(spacing: 4) {
                                TextField("分钟", text: $customReminderText)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 56)
                                    .font(.system(size: 11))
                                    .onSubmit(addCustomReminder)
                                Button("添加", action: addCustomReminder)
                                    .font(.system(size: 10))
                                    .buttonStyle(.plain)
                                    .foregroundColor(.accentColor)
                            }
                        }
                        // 第三行：已添加的自定义档 chips（不在预设内的选中档）
                        let customOffsets = taskReminderOffsets.filter { ![5, 10, 30, 60, 1440].contains($0) }
                        if !customOffsets.isEmpty {
                            HStack(spacing: 4) {
                                ForEach(customOffsets, id: \.self) { minutes in
                                    ReminderChip(
                                        label: Self.chipLabel(for: minutes),
                                        isOn: true
                                    ) {
                                        taskReminderOffsets.removeAll { $0 == minutes }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // 保存（Cmd+Return）
            Button {
                saveEvent()
            } label: {
                if isProcessing {
                    ProgressView()
                        .scaleEffect(0.8)
                        .frame(maxWidth: .infinity)
                } else {
                    Text("保存")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(title.isEmpty || isProcessing)
        }
        .padding(14)
        .frame(width: 340)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - 分组卡片组件（仅本视图使用）

    /// 分组卡片：小节标题 + 圆角容器（系统语义色，随深浅色模式）
    private struct FormCard<Content: View>: View {
        let title: String
        @ViewBuilder let content: Content

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                content
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
        }
    }

    /// 表单行：左标签右控件
    private struct FormRow<Content: View>: View {
        let label: String
        @ViewBuilder let content: Content

        var body: some View {
            HStack {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                Spacer()
                content
            }
            .padding(.vertical, 3)
        }
    }

    /// 提醒档位圆片：点选/取消，选中高亮描边
    private struct ReminderChip: View {
        let label: String
        let isOn: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Text(label)
                    .font(.system(size: 10.5, weight: .medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isOn ? Color.accentColor.opacity(0.16) : Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(isOn ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: isOn ? 1.2 : 0.8)
                    )
                    .foregroundColor(isOn ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)
        }
    }

    /// 档位标签：1440 的倍数→天、60 的倍数→时、其余→分
    private static func chipLabel(for minutes: Int) -> String {
        if minutes >= 1440 && minutes % 1440 == 0 { return "\(minutes / 1440)天" }
        if minutes >= 60 && minutes % 60 == 0 { return "\(minutes / 60)时" }
        return "\(minutes)分"
    }

    /// 添加自定义档位：G5 上限 1440 分钟；非法输入保留文本等待修正，不弹提示
    private func addCustomReminder() {
        guard let minutes = Int(customReminderText), minutes > 0, minutes <= 1440 else { return }
        if !taskReminderOffsets.contains(minutes) {
            taskReminderOffsets.append(minutes)
        }
        customReminderText = ""
        showCustomReminderInput = false
    }

    private func saveEvent() {
        isProcessing = true
        Task { @MainActor in
            do {
                // 非全天保存时保留原截止时间：原带时间事项按开始时间平移量平移原 endDate（时长不变，
                // 未改开始时间时截止时间保持原值）；全天转带时间无原始时长可保，才兜底开始时间 + 1 小时
                let newEndDate: Date?
                if isAllDay {
                    newEndDate = nil
                } else if !event.isAllDay, let originalStart = event.startDate, let originalEnd = event.endDate {
                    newEndDate = originalEnd.addingTimeInterval(startDate.timeIntervalSince(originalStart))
                } else {
                    newEndDate = startDate.addingTimeInterval(3600)
                }
                try calendarService.updateEvent(
                    eventID: event.id,
                    title: title,
                    startDate: startDate,
                    endDate: newEndDate,
                    isAllDay: isAllDay,
                    isReminder: event.isReminder,
                    // .none 的 rawValue 为 0，直接传入可正确清除已有优先级
                    priority: taskPriority,
                    // 多级提醒：始终传 offsets（空数组 = 清除全部提醒），单级 minutes 不再单独维护
                    reminderOffsets: taskReminderOffsets.sorted(),
                    color: taskColor
                )
                // D2/G7v2：编辑保存成功，广播缓存变更（徽标即时刷新）
                NotificationCenter.default.post(name: .cachedEventsChanged, object: nil)
                
                // 如果周期类型发生变化，处理周期任务逻辑
                if taskRecurrence != originalRecurrence {
                    calendarService.updateEventRecurrence(
                        eventID: event.id,
                        newRecurrenceType: taskRecurrence
                    )
                }
                
                // 通知外部刷新
                onSave?()
                
                onDismiss?()
            } catch {
                AppLogger.ui.error("更新事件失败: \(String(describing: error))")
                // V-23：保存失败需用户可见——原实现仅写日志，窗口无反馈停留
                // （失败时不 onDismiss，保持弹窗打开供用户修改后重试）
                let alert = NSAlert()
                alert.messageText = "保存失败"
                alert.informativeText = "更新事件时出错：\(error.localizedDescription)"
                alert.alertStyle = .warning
                alert.runModal()
            }
            isProcessing = false
        }
    }
}
