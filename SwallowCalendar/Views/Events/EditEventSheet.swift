//
//  EditEventSheet.swift
//  SwallowCalendar
//

import SwiftUI
import SwiftData
import AppKit
import os

/// 调试预览状态：仅 SC_OPEN_EDIT_PREVIEW 截图取证使用（正常路径为 nil，不生效）
struct EditPreviewState {
    var customRecurrence = false
    var validityOn = false
}

/// 内容自然高度测量值（ContentHeightPreferenceKey）定义在 FormLayout.swift，批量添加窗口共用

struct EditEventSheet: View {
    let event: CalendarEvent
    let calendarService: CalendarService
    var onDismiss: (() -> Void)?
    var onSave: (() -> Void)? = nil  // 保存成功通知回调

    @State private var title: String
    @State private var startDate: Date
    @State private var isAllDay: Bool
    // 智能跳过节假日（AC-7）：初始值从缓存读取，保存时写回
    @State private var skipHolidays = false
    // 任务有效期（spec/task-validity-period）：控件态从缓存读初值；
    // originalValidity 保存 init 快照，saveEvent 比较判定三态触碰（Equatable 精确相等）
    @State private var validityEnabled = false
    @State private var validityHasStart = false
    @State private var validityHasEnd = false
    @State private var validityStart = Date()
    @State private var validityEnd = Date()
    @State private var taskColor: EventColor?
    @State private var taskPriority: EventPriority = .none
    @State private var taskRecurrence: RecurrenceType = .none
    /// 循环规则单一真源与界面预设（12 项对齐提醒事项）
    @State private var taskPreset: RecurrencePreset = .never
    @State private var taskSpec: RecurrenceSpec?
    @State private var taskReminderOffsets: [Int] = []
    @State private var isProcessing = false
    /// 内容自然高度（供父视图驱动窗口尺寸，同时决定是否启用内部滚动）
    @State private var contentHeight: CGFloat = 0
    /// 内容高度变化回调（窗口管理器据此自适应高度）
    var onContentHeightChange: ((CGFloat) -> Void)?
    
    /// 原始 spec 快照（幂等比较真源）
    private let originalSpec: RecurrenceSpec?
    // 有效期初值快照（spec AC-6，plan step 12）：saveEvent 与当前控件态比较判定触碰
    private let originalValidity: ValidityPeriod?
    private let originalLunar: Bool

    /// 编辑面板回填快照：从缓存读取本体记录（bug: recurring-edit-sheet-mismatch——
    /// 列表行可能是 occurrence 虚拟展开行（复合 ID），用复合 ID 查主表必落空导致
    /// 周期/属性全部回填默认值，须按全项目唯一入口 parseOccurrenceID 回查本体）
    @MainActor
    static func backfillSnapshot(for eventID: String) -> CachedEvent? {
        guard let context = EventCacheService.shared.context else { return nil }
        let targetID = CachedEvent.parseOccurrenceID(eventID)?.baseID ?? eventID
        var descriptor = FetchDescriptor<CachedEvent>(
            predicate: #Predicate { $0.eventID == targetID }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// BUG-06：展开实例（复合 ID）只允许改非时间字段——写回 startDate/endDate/isAllDay
    /// 会把整条循环序列的游标回拨到该期；非实例行原样透传
    static func sanitizedTimeParams(
        for eventID: String,
        startDate: Date,
        endDate: Date?,
        isAllDay: Bool
    ) -> (startDate: Date?, endDate: Date?, isAllDay: Bool?) {
        guard CachedEvent.parseOccurrenceID(eventID) != nil else {
            return (startDate, endDate, isAllDay)
        }
        return (nil, nil, nil)
    }

    /// 当前编辑对象是否为循环展开出的单期行（复合 ID）
    private var isOccurrenceInstance: Bool {
        CachedEvent.parseOccurrenceID(event.id) != nil
    }

    init(event: CalendarEvent, calendarService: CalendarService, onDismiss: (() -> Void)? = nil, onSave: (() -> Void)? = nil, preview: EditPreviewState? = nil, onContentHeightChange: ((CGFloat) -> Void)? = nil) {
        self.event = event
        self.calendarService = calendarService
        self.onDismiss = onDismiss
        self.onSave = onSave
        self.onContentHeightChange = onContentHeightChange
        _title = State(initialValue: event.title)
        _startDate = State(initialValue: event.startDate ?? Date())
        _isAllDay = State(initialValue: event.isAllDay)

        // 获取原始周期（从缓存读取本体记录，occurrence 虚拟行复合 ID 已在快照查询内解析）
        var snapshotValidity: ValidityPeriod? = nil
        // spec 初值：缓存优先（含旧档位推导），缓存缺失回退事件载体
        var snapshotSpec = event.recurrenceSpec
        var snapshotLunar = false
        if let cached = Self.backfillSnapshot(for: event.id) {
            _taskRecurrence = State(initialValue: cached.recurrenceType)
            snapshotSpec = cached.recurrenceSpec
            snapshotLunar = cached.isLunar
            // 界面预设按 spec 反推（旧档位 monthly/yearly 的锚点用缓存起始日）
            _taskPreset = State(initialValue: RecurrenceSpec.preset(
                for: cached.recurrenceSpec,
                anchor: cached.originStartDate ?? cached.startDate ?? event.startDate ?? Date()
            ))
            _taskSpec = State(initialValue: cached.recurrenceSpec)
            _taskPriority = State(initialValue: EventPriority(rawValue: cached.priority) ?? .none)
            // 多级提醒初始选中：保留 0（到点）与负值（延后）档，不用 >0 过滤丢档
            _taskReminderOffsets = State(initialValue: cached.reminderOffsets)
            if let hex = cached.eventColorHex {
                _taskColor = State(initialValue: EventColor(rawValue: hex))
            }
            // 智能跳过节假日初始值（AC-7：编辑面板可修改并保存）
            _skipHolidays = State(initialValue: cached.skipHolidays)
            // 有效期初值（spec AC-6，plan step 12）：任一端存在即视为已设置，控件态按端读取
            if cached.validStartDate != nil || cached.validEndDate != nil {
                let period = ValidityPeriod(start: cached.validStartDate, end: cached.validEndDate)
                snapshotValidity = period
                // init 内须经 State(initialValue:) 赋初值（直接赋值 wrappedValue 需 self 完全初始化）
                _validityEnabled = State(initialValue: true)
                _validityHasStart = State(initialValue: cached.validStartDate != nil)
                _validityHasEnd = State(initialValue: cached.validEndDate != nil)
                if let s = cached.validStartDate { _validityStart = State(initialValue: s) }
                if let e = cached.validEndDate { _validityEnd = State(initialValue: e) }
            }
        } else if let spec = snapshotSpec {
            // 缓存缺失时按事件载体回填，避免编辑面板周期显示为「永不」
            _taskSpec = State(initialValue: spec)
            _taskRecurrence = State(initialValue: spec.legacyType)
            _taskPreset = State(initialValue: RecurrenceSpec.preset(for: spec, anchor: event.startDate ?? Date()))
        }
        self.originalSpec = snapshotSpec
        self.originalLunar = snapshotLunar
        self.originalValidity = snapshotValidity

        // 调试预览态：仅供 SC_OPEN_EDIT_PREVIEW 截图取证（正常路径 preview 为 nil，不生效）
        if let preview {
            if preview.customRecurrence {
                _taskPreset = State(initialValue: .custom)
                _taskSpec = State(initialValue: RecurrenceSpec(frequency: .weekly, interval: 1))
                _taskRecurrence = State(initialValue: .weekly)
            }
            if preview.validityOn {
                // 有效期仅对循环任务显示：未指定自定义周期时补一个「每天」以呈现该组
                if !preview.customRecurrence {
                    _taskPreset = State(initialValue: .daily)
                    _taskSpec = State(initialValue: RecurrenceSpec(frequency: .daily, interval: 1))
                    _taskRecurrence = State(initialValue: .daily)
                }
                let base = event.startDate ?? Date()
                _validityEnabled = State(initialValue: true)
                _validityHasStart = State(initialValue: true)
                _validityHasEnd = State(initialValue: true)
                _validityStart = State(initialValue: base)
                _validityEnd = State(initialValue: Calendar.current.date(byAdding: .month, value: 1, to: base) ?? base)
            }
        }
    }

    var body: some View {
        // 与主界面 ContentView 完全同一套材质实现：同一 VisualEffectView 包装、
        // 同一 material/blendingMode/state，靠 ignoresSafeArea 铺满整窗（含标题栏）
        ZStack {
            VisualEffectView()
                .ignoresSafeArea()

            // 内容高度由父视图驱动窗口尺寸；超过上限时才启用滚动，避免内容被裁
            ScrollView(.vertical) {
                contentBody
                    .frame(width: 340)
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

    /// 内容自适应的最大高度：常规展开态（下限 487，周期自定义/有效期约 +200）都能完整显示；
    /// 仅当备注多行 + 面板全展开等极端情况超限时，窗口不再长高、内容改为内部滚动
    static let maxContentHeight: CGFloat = 720

    /// 内容区（分组顺序与控件保持原样）
    private var contentBody: some View {
        VStack(spacing: FormMetrics.sectionSpacing) {

            // 分组卡片：基本信息
            FormSection("基本信息") {
                VStack(alignment: .leading, spacing: FormMetrics.rowSpacing) {
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
                            .frame(height: 56)
                            .padding(2)
                            // 隐藏 TextEditor 自带的实色文本背景，让半透明卡片材质透上来
                            .scrollContentBackground(.hidden)
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                    )

                    FormRow("全天") {
                        Toggle("", isOn: $isAllDay)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            // BUG-06：单期行不允许改时间，避免回拨整条序列游标
                            .disabled(isOccurrenceInstance)
                    }

                    FormRow("日期") {
                        DatePicker("", selection: $startDate, displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute])
                            .labelsHidden()
                            .disabled(isOccurrenceInstance)
                            // 固有宽度 + FormRow 的 trailing 容器：右边缘与「全天」开关共线
                            .formControlSizing()
                    }

                    if isOccurrenceInstance {
                        FormHint("当前为循环单期，时间修改请作用于整条系列")
                    }
                }
            }

            // 分组卡片：重复（循环语义集中一处：周期/跳过节假日/限制有效期，spec 定案）
            FormSection("重复") {
                VStack(alignment: .leading, spacing: FormMetrics.rowSpacing) {
                    FormRow("周期") {
                        RecurrencePickerView(
                            preset: Binding(
                                get: { taskPreset },
                                set: { taskPreset = $0 }
                            ),
                            spec: Binding(
                                get: { taskSpec },
                                set: { taskSpec = $0; taskRecurrence = $0?.legacyType ?? .none }
                            ),
                            anchor: startDate,
                            isLunar: originalLunar
                        )
                    }

                    // 「跳过节假日」已从表单移除（周期预设「工作日」覆盖常见场景）；
                    // 存量 skipHolidays==true 继续按原语义生效，此处只读呈现，避免"已开启却无处可看"
                    if skipHolidays {
                        FormRow("跳过节假日") {
                            Text("已开启（保留原设置，不可在此修改）")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }

                    // 任务有效期（spec/task-validity-period）：仅循环任务显示
                    if taskRecurrence != .none {
                        FormRow("限制有效期") {
                            // 开启时与新增任务同款默认：开始端勾选=事件开始日期、结束端不勾选
                            Toggle("", isOn: Binding(
                                get: { validityEnabled },
                                set: {
                                    validityEnabled = $0
                                    if $0 {
                                        validityHasStart = true
                                        validityStart = startDate
                                        validityHasEnd = false
                                    }
                                }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                        }
                        if validityEnabled {
                            FormRow("有效期起") {
                                HStack(spacing: 6) {
                                    Toggle("", isOn: $validityHasStart)
                                        .toggleStyle(.switch)
                                        .labelsHidden()
                                    DatePicker("", selection: $validityStart, displayedComponents: [.date, .hourAndMinute])
                                        .labelsHidden()
                                        .disabled(!validityHasStart)
                                        // 固有宽度：整行由 FormRow 右贴，日期右缘（箭头）落在统一基准线
                                        .formControlSizing()
                                }
                            }
                            FormRow("有效期止") {
                                HStack(spacing: 6) {
                                    Toggle("", isOn: $validityHasEnd)
                                        .toggleStyle(.switch)
                                        .labelsHidden()
                                    DatePicker("", selection: $validityEnd, displayedComponents: [.date, .hourAndMinute])
                                        .labelsHidden()
                                        .disabled(!validityHasEnd)
                                        .formControlSizing()
                                }
                            }
                            FormHint("有效期含起止端点，精确到时分（如 10:00 起、18:00 止）")
                        }
                    }
                }
            }

            // 分组卡片：属性
            FormSection("属性") {
                VStack(alignment: .leading, spacing: FormMetrics.rowSpacing) {
                    FormRow("颜色") {
                        FormColorSwatches(selection: $taskColor)
                    }
                    FormRow("优先级") {
                        FormPriorityPicker(selection: $taskPriority)
                    }
                }
            }

            // 分组卡片：提醒（9 项预设 + 自定义，对齐提醒事项）
            FormSection("提醒") {
                FormRow("提前提醒") {
                    ReminderLeadPickerView(offsets: $taskReminderOffsets)
                }
            }

            // 底部操作行：标题已在窗口标题栏，内容区不再重复；取消保留（红叉之外的第二入口）
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("取消") {
                    onDismiss?()
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    saveEvent()
                } label: {
                    if isProcessing {
                        ProgressView()
                            .scaleEffect(0.8)
                            .frame(width: 64)
                    } else {
                        Text("保存")
                            .frame(width: 64)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(title.isEmpty || isProcessing)
            }
        }
        .padding(14)
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
                // 有效期三态（spec AC-6，plan step 12）：与 init 快照比较——
                // 相等 = 未触碰传 nil 保持原值；不等 = .some(currentValidity)
                // （开关关 = 内层 nil 清除；开关开 = 按两端勾选组装，归一化落库由服务层完成）
                let currentValidity: ValidityPeriod? = validityEnabled ? ValidityPeriod(
                    start: validityHasStart ? validityStart : nil,
                    end: validityHasEnd ? validityEnd : nil
                ) : nil
                let validityParam: ValidityPeriod?? = currentValidity == originalValidity ? nil : .some(currentValidity)
                // BUG-06：展开实例传 nil 时间参数，服务层也会二次丢弃（双保险）
                let timeParams = Self.sanitizedTimeParams(
                    for: event.id,
                    startDate: startDate,
                    endDate: newEndDate,
                    isAllDay: isAllDay
                )
                try calendarService.updateEvent(
                    eventID: event.id,
                    title: title,
                    startDate: timeParams.startDate,
                    endDate: timeParams.endDate,
                    isAllDay: timeParams.isAllDay,
                    isReminder: event.isReminder,
                    // .none 的 rawValue 为 0，直接传入可正确清除已有优先级
                    priority: taskPriority,
                    // 多级提醒：始终传 offsets（空数组 = 清除全部提醒），单级 minutes 不再单独维护
                    reminderOffsets: taskReminderOffsets.sorted(),
                    color: taskColor,
                    skipHolidays: skipHolidays,
                    validity: validityParam
                )
                // 如果循环规则发生变化，写入 spec 真源并同步提醒 EK 规则
                if taskSpec != originalSpec {
                    calendarService.updateEventRecurrence(
                        eventID: event.id,
                        newSpec: taskSpec
                    )
                }

                // BUG-16：广播必须晚于周期更新——原实现先广播再改周期，列表按旧序列渲染且不再刷新
                NotificationCenter.default.post(name: .cachedEventsChanged, object: nil)
                
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
