//
//  EditEventSheet.swift
//  SwallowCalendar
//

import SwiftUI
import SwiftData

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
            let descriptor = FetchDescriptor<CachedEvent>()
            if let allCached = try? context.fetch(descriptor),
               let cached = allCached.first(where: { $0.eventID == event.id }) {
                originalRec = cached.recurrenceType
                _taskRecurrence = State(initialValue: cached.recurrenceType)
            }
        }
        self.originalRecurrence = originalRec
    }

    var body: some View {
        VStack(spacing: 16) {
            // 标题栏
            HStack {
                Text("修改事件")
                    .font(.headline)
                Spacer()
                Button("取消") {
                    onDismiss?()
                }
                .buttonStyle(.plain)
            }

            Divider()

            // 标题输入
            TextField("事件标题", text: $title)
                .textFieldStyle(.roundedBorder)

            // 日期时间选择
            Toggle("全天事件", isOn: $isAllDay)

            if !isAllDay {
                DatePicker("开始时间", selection: $startDate, displayedComponents: [.date, .hourAndMinute])
            } else {
                DatePicker("日期", selection: $startDate, displayedComponents: .date)
            }

            Divider()

            // 颜色选择
            HStack {
                Text("颜色:")
                Spacer()
                ForEach(EventColor.allCases, id: \.self) { color in
                    Circle()
                        .fill(Color(hex: color.rawValue))
                        .frame(width: 20, height: 20)
                        .overlay(
                            Circle().stroke(taskColor == color ? Color.primary : Color.clear, lineWidth: 1)
                        )
                        .onTapGesture {
                            taskColor = taskColor == color ? nil : color
                        }
                }
            }

            // 优先级
            HStack {
                Text("优先级:")
                Spacer()
                Picker("", selection: $taskPriority) {
                    ForEach(EventPriority.allCases, id: \.self) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .labelsHidden()
                .frame(width: 100)
            }

            // 周期
            HStack {
                Text("周期:")
                Spacer()
                Picker("", selection: $taskRecurrence) {
                    Text("1次").tag(RecurrenceType.none)
                    Text("每天").tag(RecurrenceType.daily)
                    Text("每周").tag(RecurrenceType.weekly)
                    Text("每月").tag(RecurrenceType.monthly)
                    Text("每年").tag(RecurrenceType.yearly)
                }
                .labelsHidden()
                .frame(width: 100)
            }

            // 提醒时间
            HStack {
                Text("提醒:")
                Spacer()
                Picker("", selection: $taskReminderMinutes) {
                    Text("不提醒").tag(0)
                    Text("5分钟前").tag(5)
                    Text("10分钟前").tag(10)
                    Text("30分钟前").tag(30)
                    Text("1小时前").tag(60)
                    Text("1天前").tag(1440)
                }
                .labelsHidden()
                .frame(width: 120)
            }

            Spacer()

            // 保存按钮
            Button {
                saveEvent()
            } label: {
                if isProcessing {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Text("保存")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(title.isEmpty || isProcessing)
        }
        .padding()
        .frame(width: 350, height: 450)
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
                    isReminder: event.isReminder
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
                // 更新事件失败，记录到日志系统（待实现）
            }
            isProcessing = false
        }
    }
}
