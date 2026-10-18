//
//  EditEventSheet.swift
//  SwallowCalendar
//

import SwiftUI
import SwiftData
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
    @State private var taskReminderMinutes: Int = 10
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
                _taskReminderMinutes = State(initialValue: cached.reminderMinutes)
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

                FormRow(label: "提醒") {
                    Picker("", selection: $taskReminderMinutes) {
                        Text("不提醒").tag(0)
                        Text("5分钟前").tag(5)
                        Text("10分钟前").tag(10)
                        Text("30分钟前").tag(30)
                        Text("1小时前").tag(60)
                        Text("1天前").tag(1440)
                    }
                    .labelsHidden()
                    .frame(width: 110)
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

    private func saveEvent() {
        isProcessing = true
        Task { @MainActor in
            do {
                try calendarService.updateEvent(
                    eventID: event.id,
                    title: title,
                    startDate: startDate,
                    endDate: isAllDay ? nil : startDate.addingTimeInterval(3600),
                    isAllDay: isAllDay,
                    isReminder: event.isReminder,
                    // .none 的 rawValue 为 0，直接传入可正确清除已有优先级
                    priority: taskPriority,
                    reminderMinutes: taskReminderMinutes,
                    color: taskColor
                )
                
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
                AppLogger.ui.error("更新事件失败: \(String(describing: error), privacy: .public)")
            }
            isProcessing = false
        }
    }
}
