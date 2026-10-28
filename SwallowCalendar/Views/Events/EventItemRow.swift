//
//  EventItemRow.swift
//  SwallowCalendar
//

import SwiftUI

struct EventItemRow: View {
    let event: CalendarEvent
    let onEdit: ((CalendarEvent) -> Void)?
    let onDelete: ((CalendarEvent) -> Void)?
    let onComplete: ((CalendarEvent) -> Void)?
    let onUncomplete: ((CalendarEvent) -> Void)?
    var isOverdue: Bool = false

    @Environment(AppSettings.self) private var appSettings
    @State private var isHovered = false

    init(
        event: CalendarEvent,
        onEdit: ((CalendarEvent) -> Void)? = nil,
        onDelete: ((CalendarEvent) -> Void)? = nil,
        onComplete: ((CalendarEvent) -> Void)? = nil,
        onUncomplete: ((CalendarEvent) -> Void)? = nil,
        isOverdue: Bool = false
    ) {
        self.event = event
        self.onEdit = onEdit
        self.onDelete = onDelete
        self.onComplete = onComplete
        self.onUncomplete = onUncomplete
        self.isOverdue = isOverdue
    }

    var body: some View {
        HStack(spacing: 8) {
            // 完成/未完成复选框
            if event.isCompleted {
                Button {
                    onUncomplete?(event)
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.green)
                }
                .buttonStyle(.plain)
                .help("标记未完成")
            } else {
                Button {
                    onComplete?(event)
                } label: {
                    Image(systemName: "circle")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("标记完成")
            }

            // 日历颜色标识（优先使用用户选择的颜色）
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(hex: event.eventColorHex ?? event.calendarColorHex))
                .frame(width: 3, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .strikethrough(event.isCompleted, color: .secondary)
                    .foregroundColor(event.isCompleted ? .secondary : .primary)

                HStack(spacing: 4) {
                    if event.startDate == nil {
                        // 无到期时间的提醒
                        Text("无到期时间")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    } else if event.hasTime {
                        Text(formattedDateTime)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)

                        if isOverdue {
                            Text("已过期")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.red)
                        } else {
                            countdownBorderedView
                        }
                    } else {
                        // 全天事件：显示日期 + 倒计时
                        Text(formattedDate)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)

                        if isOverdue {
                            Text("已过期")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.red)
                        } else {
                            countdownBorderedView
                        }
                    }

                    // 系统提醒标签
                    if event.isReminder {
                        Text("提醒")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.orange.opacity(0.15))
                            )
                    }
                }
            }

            Spacer()

            // 悬停时显示操作按钮
            if isHovered {
                HStack(spacing: 4) {
                    if onEdit != nil {
                        Button {
                            // 打开编辑窗口前先收起 hover 弹窗：
                            // 鼠标仍悬停在行内不会触发 onHover(false)，必须显式置 false，否则弹窗悬浮在编辑窗口之上
                            isHovered = false
                            onEdit?(event)
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("修改")
                    }

                    if onDelete != nil {
                        Button {
                            onDelete?(event)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                        .help("删除")
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
        // hover 详情弹窗：锚点为整行 bounds，复用日历格子弹窗的窗口/气泡/三角指向；
        // 列表滚动或窗口移动导致行位移时关闭（避免锚点陈旧），重新 hover 才会再弹出
        .background(
            GeometryReader { geo in
                let globalFrame = geo.frame(in: .global)
                CellPopoverPresenter(
                    isPresented: isHovered,
                    positioningRect: CGRect(origin: .zero, size: geo.size),
                    maxWidth: 260,
                    content: EventRowPopoverContent(event: event)
                )
                .onChange(of: globalFrame) { _, _ in
                    if isHovered {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isHovered = false
                        }
                    }
                }
            }
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }

    /// 带主题色背景的倒计时标签（使用独立刷新机制）
    private var countdownBorderedView: some View {
        CountdownTextView(
            startDate: event.startDate,
            accentColorHex: appSettings.accentColorHex,
            eventID: event.id
        )
    }

    private var formattedDate: String {
        guard let start = event.startDate else { return "" }
        return Self.dateFormatter.string(from: start)
    }

    private var formattedDateTime: String {
        guard let start = event.startDate else { return "" }
        return Self.dateTimeFormatter.string(from: start)
    }
    
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM/dd"
        return f
    }()
    
    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM/dd HH:mm"
        return f
    }()
}

/// 列表条目详情弹窗内容：完整标题 + 时间/优先级/重复/日历来源/提醒标签/完成状态
/// （内边距由 CellPopoverPresenter 的 chrome 统一提供，此处不加 padding）
private struct EventRowPopoverContent: View {
    let event: CalendarEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 完整标题（不截断，全部显示）
            Text(event.title)
                .font(.system(size: 13, weight: .semibold))
                .strikethrough(event.isCompleted, color: .secondary)

            if event.isCompleted {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.green)
                    Text("已完成")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            timeRows

            // 智能跳过节假日状态行（语义 v3 静默跳过）：勾选任务 startDate 落休日/周末当天
            // 不显示不提醒，任务保留原日期可自行改期；落班日/工作日照常执行不显示该行
            if HolidaySkipResolver.isSkipped(of: event, context: EventCacheService.shared.context) {
                infoRow(label: "跳过", value: "已智能跳过（休日/周末不提醒，可修改日期）")
            }

            // 优先级（0=无，不显示）
            if let priority = EventPriority(rawValue: event.priority), priority != .none {
                infoRow(label: "优先级", value: priority.displayName)
            }

            // 周期类型（不重复不显示）
            if event.recurrenceType != .none {
                infoRow(label: "重复", value: event.recurrenceType.rawValue)
            }

            // 有效期区间（spec/task-validity-period）：仅循环任务且已设置时显示，缺省端显示「不限」
            if event.recurrenceType != .none, let validity = event.validity {
                infoRow(label: "有效期", value: Self.validityText(validity))
            }

            // 日历来源：色点 + 日历名（与行内色条同色）
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(hex: event.eventColorHex ?? event.calendarColorHex))
                    .frame(width: 7, height: 7)
                Text(event.calendarTitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            // 系统提醒标签（与行内同款样式）
            if event.isReminder {
                Text("系统提醒")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.orange.opacity(0.15))
                    )
            }
        }
        .frame(minWidth: 160, alignment: .leading)
    }

    /// 时间信息：待办/提醒语义下 startDate 即到期时间
    @ViewBuilder
    private var timeRows: some View {
        if let start = event.startDate {
            if event.hasTime {
                infoRow(label: "到期", value: Self.timeText(for: start))
                if let end = event.endDate, end > start {
                    infoRow(label: "截止", value: Self.timeText(for: end))
                }
            } else {
                infoRow(label: "日期", value: Self.timeText(for: start) + " 全天")
            }
        } else {
            infoRow(label: "时间", value: "无到期时间")
        }
    }

    /// label 左对齐固定宽 + value 的信息行
    private func infoRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 36, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .foregroundColor(.primary)
        }
    }

    /// 今年内省略年份，跨年显示完整日期
    private static func timeText(for date: Date) -> String {
        let year = Calendar.current.component(.year, from: date)
        let currentYear = Calendar.current.component(.year, from: Date())
        if year == currentYear {
            return dateTimeFormatter.string(from: date)
        }
        return dateTimeWithYearFormatter.string(from: date)
    }

    /// 有效期展示文本（spec AC-6）：「yyyy/M/d ~ yyyy/M/d」，缺省端显示「不限」
    private static func validityText(_ validity: ValidityPeriod) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy/M/d"
        let start = validity.start.map { f.string(from: $0) } ?? "不限"
        let end = validity.end.map { f.string(from: $0) } ?? "不限"
        return "\(start) ~ \(end)"
    }

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 HH:mm"
        return f
    }()

    private static let dateTimeWithYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日 HH:mm"
        return f
    }()
}

/// 倒计时文本视图，使用 CountdownTimerManager 统一刷新
/// （internal：主界面/菜单弹层/桌面面板三处复用，样式与刷新机制单一事实源）
struct CountdownTextView: View {
    let startDate: Date?
    let accentColorHex: String
    let eventID: String

    @State private var countdownText: String = ""
    @State private var tier: CountdownFormatter.Tier = .normal
    /// countdown-overdue-color-sync：本胶囊是否处于倒计时中（remaining>0 后置 true）。
    /// 归零瞬间经 crossedDeadline 判定边沿广播 .countdownExpired，外层列表重建行后
    /// isOverdue 快照翻转 → 红字「已过期」（胶囊停留在内部 @State，外层不可见，必须广播）
    @State private var wasCountingDown = false
    @ObservedObject private var timerManager = CountdownTimerManager.shared

    var body: some View {
        Text(countdownText)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(CountdownFormatter.tierColor(tier, accentHex: accentColorHex))
            )
            .onAppear {
                updateCountdown()
                if let start = startDate, start > Date() {
                    CountdownTimerManager.shared.register(eventID: eventID, deadline: start)
                }
            }
            .onDisappear {
                CountdownTimerManager.shared.unregister(eventID: eventID)
            }
            .onChange(of: timerManager.refreshTrigger) { _, _ in
                if CountdownTimerManager.shared.shouldRefresh(eventID: eventID) {
                    updateCountdown()
                }
            }
    }
    
    private func updateCountdown() {
        guard let start = startDate else {
            countdownText = ""
            return
        }
        let remaining = start.timeIntervalSince(Date())
        // 跨零边沿广播（onAppear 首算即已过期时 wasCountingDown=false → 不广播，交给外层快照）
        if CountdownFormatter.crossedDeadline(wasCountingDown: wasCountingDown, remaining: remaining) {
            NotificationCenter.default.post(name: .countdownExpired, object: nil)
        }
        wasCountingDown = remaining > 0
        countdownText = CountdownFormatter.formatCountdown(remaining: remaining)
        tier = CountdownFormatter.tier(remaining: remaining)
    }
}

// MARK: - Color from Hex

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let scanner = Scanner(string: hex)
        var rgbValue: UInt64 = 0
        scanner.scanHexInt64(&rgbValue)

        let r = Double((rgbValue & 0xFF0000) >> 16) / 255.0
        let g = Double((rgbValue & 0x00FF00) >> 8) / 255.0
        let b = Double(rgbValue & 0x0000FF) / 255.0

        self.init(red: r, green: g, blue: b)
    }
}
