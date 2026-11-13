//
//  TodayTodoPopoverView.swift
//  SwallowCalendar
//
//  hover 弹层内容：今天待办列表
//  数据 = 用户分类 + 无时间或今天内（含已完成，置灰置底）；
//  智能跳过节假日：勾选任务 startDate 落休日/周末当天静默跳过，不显示
//  谓词粗筛 + TodayTodoSorter 精确判定与排序（排序行为单测覆盖）
//

import SwiftUI
import SwiftData

struct TodayTodoPopoverView: View {
    @State private var todos: [CachedEvent] = []
    /// 超时判定基准时刻（reload 时更新；弹层显示期间时间推移不自动刷新，弹层生命短暂可接受）
    @State private var reloadAt: Date = Date()
    /// 过滤档位（今天/本周/本月/本年，面板同款四档）；初值 = init 注入的初始档
    @State private var mode: EventFilterMode
    /// 主题色（倒计时胶囊用）；环境由 AppDelegate 弹层挂载处注入（主面板同款）
    @Environment(AppSettings.self) private var appSettings

    private let calendar = Calendar.current

    init(initialMode: EventFilterMode) {
        _mode = State(initialValue: initialMode)
    }

    /// 弹层初始档解析（bug: popover-anchor 回归）：上次记忆档，无记忆回退本月。
    /// 必须在 popover.show 前定死——show 后 onAppear 切档会二次改变内容尺寸，
    /// macOS 26 弹层重排时序不稳（实测脱离锚点错位/高度不跟手）
    static func resolveInitialMode(from settings: AppSettings) -> EventFilterMode {
        settings.hoverFilterModeEnum ?? .thisMonth
    }

    /// 弹层内容区固定高度（bug: popover-fixed-height 回归）：与档位/数据量无关，
    /// 空态留白属预期。尺寸恒定规避 macOS 26「show 后 contentSize 变化不重排」
    /// （高度定格）问题；值沿用原列表上限 420
    static let contentHeight: CGFloat = 420

    /// 弹层宽度（视图与 show 前尺寸同源，避免多处硬编码失配）
    static let contentWidth: CGFloat = 300

    /// show 前兜底内容尺寸（bug: popover-initial-position 第4轮）：
    /// macOS 26 在 show 前不执行 SwiftUI 布局，popover.contentSize 保持 {0,0}，
    /// 系统按默认 320 估算定位，随后内容渲染成 457 高但窗口原点不动 → 顶部
    /// 冲出菜单栏（bug-anchor3 实测：上沿超屏顶 111pt）。优先用 resolvedContentSize
    /// 实测真实尺寸；实测异常（0 值）时退回本兜底（内容区 420 + 档位行约 37 + 余量）
    static let showContentSize: NSSize = NSSize(width: contentWidth, height: contentHeight + 40)

    /// show 前尺寸解析（纯函数，单测覆盖）：优先实测 (fittingSize)，异常值退回兜底。
    /// 实测可消除硬编码余量——外观点改变 picker 行高时也不会再错位
    static func resolvedContentSize(measured: NSSize?) -> NSSize {
        guard let measured, measured.width > 0, measured.height > 0 else {
            return showContentSize
        }
        return NSSize(width: contentWidth, height: measured.height)
    }

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
            // 用户反馈：弹层分段控件点击后画蓝色聚焦环——桥接 AppKit 控件的
            // focus effect 用官方禁用 API（桌面面板 Picker 同款先例）
            .focusEffectDisabled()
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .onChange(of: mode) { _, newMode in
                // 改档即持久化（下次启动加载上次选择）
                appSettings.hoverFilterMode = newMode.rawValue
                reload()
            }

            Divider()

            Group {
                if todos.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            // 高度 = 固定 contentHeight：与档位/数据量无关，空态/列表/切档均不改变弹层尺寸
            .frame(height: Self.contentHeight)
        }
        .frame(width: Self.contentWidth)
        .onAppear {
            // 初始档已 init 注入（show 前定死）；内容尺寸已由 popover.contentSize
            // 在 show 前告知系统（见 showContentSize），此处仅首刷数据，无尺寸突变
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
        .frame(maxHeight: Self.contentHeight)
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
                        // 未过期倒计时胶囊，对齐主界面 EventItemRow
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
        // 用户需求：条目文字不可点击唤起主面板——该行为仅由状态栏图标点击触发
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
        // 候选加载/节假日过滤/档位精判抽共享；弹层排序（升序）为本视图专属
        todos = TodayTodoSorter.sort(
            TodoListLoader.loadCandidates(mode: mode, now: now),
            now: now,
            calendar: calendar
        )
    }

    /// 勾选完成/取消完成：共享链路（桌面面板同款）
    private func toggleComplete(_ event: CachedEvent) {
        TodoListLoader.toggleComplete(event)
    }
}
