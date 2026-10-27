//
//  DesktopTodoPanelView.swift
//  SwallowCalendar
//
//  桌面常驻待办面板内容视图（spec: desktop-todo-panel）
//  四档筛选（下拉）+ 状态筛选（全部/待办/已办）+ 仅用户待办（八轮）+ 用户待办可勾选
//

import AppKit
import SwiftUI
import SwiftData

// MARK: - 四档筛选纯函数

/// 桌面面板筛选口径（DesktopTodoPanelFilterTests 覆盖）：
/// - 仅用户待办（八轮需求：霜降等节气/节假日来自系统/订阅日历，排除；口径对齐弹层/状态栏/提醒服务）
/// - 无日期待办无到期语义，四档恒显示
/// - 有日期按 EventFilterMode.dateRange 左闭右开区间判定（周起始日由 AppSettings 决定）
enum DesktopTodoPanelFilter {
    /// 面板固定四档（复用 EventFilterMode 但不含 .all——spec 明确不设「全部」档）
    static let modes: [EventFilterMode] = [.today, .thisWeek, .thisMonth, .thisYear]

    static func included(
        _ event: CachedEvent,
        mode: EventFilterMode,
        now: Date
    ) -> Bool {
        // 八轮需求：仅用户分类收录，系统/订阅日历内容不显示
        guard event.category == .user else { return false }
        guard let start = event.startDate else { return true }
        let range = mode.dateRange(from: now)
        return start >= range.start && start < range.end
    }
}

// MARK: - 时间显示纯函数

/// 行尾时间显示规则（DesktopTodoPanelFilterTests 覆盖，用户需求：非今天日期要显示全）：
/// - 今天：HH:mm（全天显示「全天」）
/// - 同年非今天：M月d日 HH:mm（全天显示「M月d日 全天」）
/// - 跨年：yyyy年M月d日 HH:mm（全天显示「yyyy年M月d日 全天」）
enum DesktopTodoPanelTimeText {
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    private static let dayWithYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年M月d日"
        return formatter
    }()

    static func text(
        for date: Date,
        isAllDay: Bool,
        now: Date,
        calendar: Calendar
    ) -> String {
        // 今天：保持原有紧凑时刻显示
        if calendar.isDate(date, inSameDayAs: now) {
            return isAllDay ? "全天" : timeFormatter.string(from: date)
        }
        // 非今天：带上日期，跨年再带年份，保证「看得明白是哪天」
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let dayText = sameYear ? dayFormatter.string(from: date) : dayWithYearFormatter.string(from: date)
        return isAllDay ? "\(dayText) 全天" : "\(dayText) \(timeFormatter.string(from: date))"
    }
}

// MARK: - 状态筛选纯函数

/// 状态筛选（DesktopTodoPanelFilterTests 覆盖，用户需求：新增状态条件 全部/待办（默认）/已办）
enum DesktopTodoPanelStatusFilter: String, CaseIterable {
    case all = "全部"
    case todo = "待办"
    case done = "已办"

    /// 按完成态判定收录
    func includes(isCompleted: Bool) -> Bool {
        switch self {
        case .all: return true
        case .todo: return !isCompleted
        case .done: return isCompleted
        }
    }
}

// MARK: - 面板排序纯函数

/// 面板排序（DesktopTodoPanelFilterTests 覆盖，用户需求：无到期日期排最前，其余按时间升序——七轮由降序改回升序）：
/// - 已完成仍置底（保留原口径）
/// - 组内：无日期在前，有日期按开始时间从早到晚（升序），同时刻按标题稳定排序避免刷新抖动
/// - 面板专属排序：弹层 TodayTodoSorter（升序）行为不变
enum DesktopTodoPanelSort {
    static func sort(_ events: [CachedEvent]) -> [CachedEvent] {
        events.sorted { a, b in
            if a.isCompleted != b.isCompleted { return !a.isCompleted }
            switch (a.startDate, b.startDate) {
            case (nil, nil):
                return a.title < b.title
            case (nil, _):
                return true
            case (_?, nil):
                return false
            case (let d1?, let d2?):
                if d1 != d2 { return d1 < d2 }
                return a.title < b.title
            }
        }
    }
}

// MARK: - 面板拖动

/// 拖动起点信息（按下瞬间快照：窗口 origin + 全局鼠标位置，位移 = 两差值之和）
private struct PanelDragStart {
    let windowOrigin: CGPoint
    let mouse: CGPoint
}

// MARK: - 面板内容视图

/// 桌面常驻面板内容：四档筛选 + 仅用户待办（八轮）+ 用户待办可勾选完成
/// （行 UI 参照 TodayTodoPopoverView；无点击唤起、无超时标签——spec Out of scope）
struct DesktopTodoPanelView: View {
    @Environment(AppSettings.self) private var appSettings

    @State private var todos: [CachedEvent] = []
    @State private var mode: EventFilterMode = .today
    /// 状态筛选（用户需求：全部/待办（默认）/已办；会话内记忆）
    @State private var statusFilter: DesktopTodoPanelStatusFilter = .todo
    /// 排序基准时刻（reload 时更新）
    @State private var reloadAt: Date = Date()
    /// 置顶开关（UI 态；窗口层级由 Manager.setPinned 切换，会话内记忆）
    @State private var isPinned = false
    /// 拖动起点快照（仅按下首帧与松开各写一次，拖动过程零状态更新 → 无逐帧重排）
    @State private var dragStart: PanelDragStart?

    private let calendar = Calendar.current

    var body: some View {
        VStack(spacing: 0) {
            // 筛选行（六轮需求：四档改下拉 + 状态下拉 + 置顶并入本行最右；
            // 八轮需求：行首应用名改应用图标）
            HStack(spacing: 6) {
                // 应用图标（与下拉行高匹配的 16pt 固定尺寸）
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 16, height: 16)

                Picker("时段", selection: $mode) {
                    ForEach(DesktopTodoPanelFilter.modes, id: \.self) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                // 九轮需求：点击后桥接控件不画蓝色聚焦环（.focusable(false) 不作用于
                // 桥接 AppKit 控件的 focus effect，需用官方禁用 API；先例 CalendarHeaderView）
                .focusEffectDisabled()

                Picker("状态", selection: $statusFilter) {
                    ForEach(DesktopTodoPanelStatusFilter.allCases, id: \.self) { s in
                        Text(s.rawValue).tag(s)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .focusEffectDisabled()

                Spacer(minLength: 8)

                // 置顶开关（用户确认：并入筛选行最右侧）
                Button {
                    isPinned.toggle()
                    DesktopTodoPanelManager.shared.setPinned(isPinned)
                } label: {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .foregroundStyle(isPinned ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(isPinned ? "取消置顶" : "置顶显示")
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)

            Divider()

            Group {
                if todos.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .background(.ultraThinMaterial)
        // 面板拖动（七轮定稿）：列表区被 ScrollView 的 NSScrollView 桥接 view 覆盖，
        // 六轮 performDrag 背景桥接 hitTest 永不命中而失效；DragGesture 恰好在筛选行/
        // 空态区可达 = 标题栏拖动语义。minimumDistance 区分点击与拖动；onChanged 用
        // NSEvent.mouseLocation 全局坐标绝对定位移窗（起点快照 + 差值，无累计误差），
        // dragStart 仅起止各写一次 @State，拖动过程零 SwiftUI 重排
        .gesture(
            DragGesture(minimumDistance: 5)
                .onChanged { _ in
                    // 拖动回调时 currentEvent 即面板窗口的鼠标事件
                    guard let window = NSApp.currentEvent?.window else { return }
                    let mouse = NSEvent.mouseLocation
                    if dragStart == nil {
                        dragStart = PanelDragStart(windowOrigin: window.frame.origin, mouse: mouse)
                    }
                    guard let start = dragStart else { return }
                    window.setFrameOrigin(
                        CGPoint(x: start.windowOrigin.x + (mouse.x - start.mouse.x),
                                y: start.windowOrigin.y + (mouse.y - start.mouse.y))
                    )
                }
                .onEnded { _ in dragStart = nil }
        )
        .tint(Color(hex: appSettings.accentColorHex))
        .onAppear { reload() }
        // 勾选完成走 .cachedEventsChanged 广播（主面板同款链路），面板即时刷新
        .onReceive(NotificationCenter.default.publisher(for: .cachedEventsChanged)) { _ in
            reload()
        }
        // 跨天重查当前档位（如「今天」档跨天后刷新）
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            reload()
        }
        .onChange(of: mode) { _, _ in
            reload()
        }
        .onChange(of: statusFilter) { _, _ in
            reload()
        }
    }

    // MARK: 子视图

    private var list: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(todos, id: \.eventID) { event in
                    row(event)
                    Divider()
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// 单行：勾选框（仅用户待办显示）+ 标题 + 时间；完成态 strikethrough 置灰
    private func row(_ event: CachedEvent) -> some View {
        HStack(spacing: 8) {
            if event.category == .user {
                Button {
                    toggleComplete(event)
                } label: {
                    Image(systemName: event.isCompleted ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(event.isCompleted ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                // 去掉键盘焦点 focus ring（弹层同款教训）
                .focusable(false)
            }

            Text(event.title)
                .font(.body)
                .strikethrough(event.isCompleted)
                .foregroundStyle(event.isCompleted ? Color.secondary : Color.primary)
                .lineLimit(1)
                // 面板文字可复制（用户需求；SwiftUI Text 默认不可选中）
                .textSelection(.enabled)

            Spacer(minLength: 8)

            if let start = event.startDate {
                // 非今天带日期、跨年带年份（用户需求：时间显示全，看得明白）
                Text(DesktopTodoPanelTimeText.text(
                    for: start,
                    isAllDay: event.isAllDay,
                    now: reloadAt,
                    calendar: calendar
                ))
                .font(.caption)
                .foregroundStyle(.secondary)

                // 过期红字 + 未过期倒计时胶囊，对齐主界面 EventItemRow（bug: status-views-countdown-missing）
                if TodayTodoSorter.isOverdue(event, now: reloadAt) {
                    Text("已过期")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.red)
                } else if !event.isCompleted {
                    CountdownTextView(
                        startDate: event.startDate,
                        accentColorHex: appSettings.accentColorHex,
                        eventID: event.eventID
                    )
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            // 空态文案跟随状态档（已办/待办）
            Text(statusFilter == .done ? "当前时段没有已办" : "当前时段没有待办")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    // MARK: 数据

    private func reload(now: Date = Date()) {
        reloadAt = now
        guard EventCacheService.shared.context != nil else {
            todos = []
            return
        }
        // bug: status-popover-panel-recurring-invisible：改走展开链路候选（循环任务
        // 档位区间实例可见），替代原 B-27 直查主表谓词；无日期行由候选方法补查保留
        // （八轮需求：排除系统/订阅日历内容，如霜降等节气/节假日——候选方法已限定用户分类）
        let range = mode.dateRange(from: now)
        let fetched = EventCacheService.shared.userTodoCandidates(from: range.start, to: range.end)
        // 智能跳过节假日（语义 v3）：勾选任务 startDate 落休日/周末当天静默跳过，不进列表
        // 纯函数精判 + 状态筛选 + 面板排序（DesktopTodoPanelFilterTests 覆盖）
        todos = DesktopTodoPanelSort.sort(
            fetched
                .filter { event in
                    !HolidaySkipResolver.isSkipped(of: event, context: EventCacheService.shared.context!)
                        && DesktopTodoPanelFilter.included(event, mode: mode, now: now)
                }
                .filter { statusFilter.includes(isCompleted: $0.isCompleted) }
        )
    }

    /// 勾选完成/取消完成：复用完成链路（EventPanelView/弹层同款）
    private func toggleComplete(_ event: CachedEvent) {
        Task {
            // 先 await 数据写入完成，再广播，避免列表回显旧状态
            await CalendarService.shared.toggleEventCompleted(
                eventID: event.eventID,
                isCompleted: !event.isCompleted,
                isReminder: event.isReminder
            )
            NotificationCenter.default.post(name: .cachedEventsChanged, object: nil)
        }
    }
}
