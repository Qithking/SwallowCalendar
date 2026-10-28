//
//  TodayTodoPopoverView.swift
//  SwallowCalendar
//
//  hover 弹层内容：今天待办列表（plan step 2）
//  数据 = 用户分类 + 无时间或今天内（含已完成，置灰置底）；
//  智能跳过节假日（语义 v3）：勾选任务 startDate 落休日/周末当天静默跳过，不显示
//  谓词粗筛 + TodayTodoSorter 精确判定与排序（排序行为单测覆盖）
//

import SwiftUI
import SwiftData

struct TodayTodoPopoverView: View {
    /// 点击条目时打开主面板的回调（由 StatusItemHoverController 注入）
    var onOpenMainPanel: () -> Void = {}

    @State private var todos: [CachedEvent] = []
    /// 超时判定基准时刻（reload 时更新；弹层显示期间时间推移不自动刷新，弹层生命短暂可接受）
    @State private var reloadAt: Date = Date()
    /// 过滤档位（bug: status-views-filter-default：今天/本周/本月/本年，面板同款四档；
    /// 初始档为应用设置「默认显示待办」，onAppear 时赋值——@State 默认值不能引用环境）
    @State private var mode: EventFilterMode = .thisMonth
    /// 主题色（倒计时胶囊用）；环境由 AppDelegate 弹层挂载处注入（主面板同款）
    @Environment(AppSettings.self) private var appSettings

    private let calendar = Calendar.current

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            // 档位筛选行（status-views-filter-default：今天/本周/本月/本年；
            // 用户需求：下拉换 tab——segmented 分段样式占满弹层宽度）
            Picker("时段", selection: $mode) {
                ForEach(DesktopTodoPanelFilter.modes, id: \.self) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .onChange(of: mode) { _, _ in reload() }

            Divider()

            Group {
                if todos.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
        }
        .frame(width: 300)
        .onAppear {
            // 初始档 = 应用设置「默认显示待办」（映射四档，「全部」回退本月）
            mode = DesktopTodoPanelFilter.defaultMode(from: appSettings.defaultFilterModeEnum)
            reload()
        }
        // 勾选完成走 .cachedEventsChanged 广播（主面板同款链路），弹层即时刷新
        .onReceive(NotificationCenter.default.publisher(for: .cachedEventsChanged)) { _ in
            reload()
        }
        // countdown-overdue-color-sync：倒计时胶囊归零后重建行，红字「已过期」即时生效
        .onReceive(NotificationCenter.default.publisher(for: .countdownExpired)) { _ in
            reload()
        }
    }

    // MARK: - 子视图

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
        .frame(maxHeight: 420)
    }

    /// 单行：勾选框 + 标题 + 时间；完成态 strikethrough + 次要色（EventItemRow 同款样式）
    private func row(_ event: CachedEvent) -> some View {
        HStack(spacing: 8) {
            Button {
                toggleComplete(event)
            } label: {
                Image(systemName: event.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(event.isCompleted ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            // macOS 点击后按钮获得键盘焦点会画蓝色方形 focus ring（视觉像单选组件选中态），去掉
            .focusable(false)

            Text(event.title)
                .font(.body)
                .strikethrough(event.isCompleted)
                .foregroundStyle(event.isCompleted ? Color.secondary : Color.primary)
                .lineLimit(1)

            Spacer(minLength: 8)

            if let start = event.startDate {
                HStack(spacing: 4) {
                    Text(event.isAllDay ? "全天" : Self.timeFormatter.string(from: start))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    // 超时标识：红色「已过期」，对齐主面板 EventItemRow 样式（口径见 TodayTodoSorter.isOverdue）
                    if TodayTodoSorter.isOverdue(event, now: reloadAt) {
                        Text("已过期")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.red)
                    } else if !event.isCompleted {
                        // 未过期倒计时胶囊，对齐主界面 EventItemRow（bug: status-views-countdown-missing）
                        CountdownTextView(
                            startDate: event.startDate,
                            accentColorHex: appSettings.accentColorHex,
                            eventID: event.eventID
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        // AC-6：点击条目文字打开主面板
        .onTapGesture { onOpenMainPanel() }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("\(mode.rawValue)没有待办")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(height: 120)
    }

    // MARK: - 数据

    private func reload(now: Date = Date()) {
        // 更新超时判定基准时刻
        reloadAt = now
        guard EventCacheService.shared.context != nil else {
            todos = []
            return
        }
        // bug: status-popover-panel-recurring-invisible：改走展开链路候选（循环任务
        // 实例可见），无日期行由候选方法补查保留；窗口按当前档位（mode.dateRange）
        let range = mode.dateRange(from: now)
        let fetched = EventCacheService.shared.userTodoCandidates(from: range.start, to: range.end)
        // 智能跳过节假日（语义 v3）：勾选任务 startDate 落休日/周末当天静默跳过，不进列表；
        // 档位精判复用面板纯函数（无日期行恒显示、跨天行按 startDate 归档，同面板语义）
        todos = TodayTodoSorter.sort(
            fetched.filter { event in
                !HolidaySkipResolver.isSkipped(of: event, context: EventCacheService.shared.context!)
                    && DesktopTodoPanelFilter.included(event, mode: mode, now: now)
            },
            now: now,
            calendar: calendar
        )
    }

    /// 勾选完成/取消完成：复用主面板完成链路（EventPanelView 范式）
    private func toggleComplete(_ event: CachedEvent) {
        Task {
            // 先 await 数据写入完成，再广播，避免列表回显旧状态
            await CalendarService.shared.toggleEventCompleted(
                eventID: event.eventID,
                isCompleted: !event.isCompleted,
                isReminder: event.isReminder
            )
            // D2/G7v2：完成路径广播缓存变更（弹层自身与徽标即时刷新）
            NotificationCenter.default.post(name: .cachedEventsChanged, object: nil)
        }
    }
}
