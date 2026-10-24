//
//  CalendarDayCell.swift
//  SwallowCalendar
//

import SwiftUI
import EventKit

/// 智能跳过节假日：弹窗行标识判定（纯函数，入仓测试）
/// 解释「原休日为什么当天列表不出现该任务」（已智能跳过，语义 v3 静默跳过）
enum CalendarPopoverHolidayMark: Equatable {
    case none       // 正常显示，无标识
    case skipped    // 该行位于原休日，任务当天静默跳过（显示「已智能跳过」）

    /// 行标识判定（语义 v3，无顺延）：
    /// - 未勾选 / startDate 非休日（班日照常、数据缺失 fail-open）→ none
    /// - date 落原日期且该任务被跳过 → skipped；其他日 → none
    /// - isSkippedDay：该事件 startDate 是否落休日（调用方预计算传入，
    ///   避免 42 格月历每格重复扫描节假日数据）
    static func mark(
        skipHolidays: Bool,
        isSkippedDay: Bool,
        startDate: Date?,
        on date: Date,
        calendar: Calendar
    ) -> CalendarPopoverHolidayMark {
        guard skipHolidays, isSkippedDay, let start = startDate,
              calendar.isDate(start, inSameDayAs: date) else { return .none }
        return .skipped
    }
}

struct CalendarEventItem: Identifiable {
    /// 日历单元格中事件条目的统一数据结构，确保标题、颜色、分类三者始终对齐
    let id = UUID()
    let title: String
    let colorHex: String
    let category: String  // "系统" | "订阅" | "用户"
    let timeText: String? // 弹窗时间列："全天" / "HH:mm" / nil（无时间信息）
    var holidayMark: CalendarPopoverHolidayMark = .none  // 弹窗行节假日标识
}

struct CalendarDayCell: View {
    @Environment(AppSettings.self) private var appSettings
    let date: Date
    let isSelected: Bool
    let isToday: Bool
    let isCurrentMonth: Bool
    let lunarText: String
    var eventItems: [CalendarEventItem] = []  // 事件条目数组，标题/颜色/分类一一对应
    var systemCalendarColor: Color = Color(hex: "#007AFF")
    var subscriptionCalendarColor: Color = Color(hex: "#FF9500")
    var isImportant: Bool = false

    /// hover 状态下沉到单元格本地：
    /// 进出格子只重渲染该格自身，不再触发父视图 42 格全网格重算（性能修复）
    @State private var isHovered = false

    // V-18：直接读 appSettings 主题色，替代 @State 复制 + onChange 同步
    private var accentColor: Color { Color(hex: appSettings.accentColorHex) }

    /// 计算属性：判断是否有系统日历事件（非订阅、非用户）
    private var hasSystemEvents: Bool {
        eventItems.contains { $0.category == "系统" }
    }
    
    /// 计算属性：判断是否有用户事件
    private var hasUserEvents: Bool {
        eventItems.contains { $0.category == "用户" }
    }
    
    /// 计算属性：判断是否有订阅事件
    private var hasSubscriptionEvents: Bool {
        eventItems.contains { $0.category == "订阅" }
    }

    // MARK: - Holiday/Work Marks

    /// V-35：休/班标记判定改用 HolidaySkipResolver 公共匹配器（关键词单一真源，
    /// 与智能跳过节假日共用口径，防两处漂移）
    private var showRestMark: Bool {
        eventItems.contains { HolidaySkipResolver.isRestTitle($0.title) }
    }

    private var showWorkMark: Bool {
        eventItems.contains { HolidaySkipResolver.isWorkTitle($0.title) }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 1) {
                Text("\(Calendar.current.component(.day, from: date))")
                    .font(.system(size: appSettings.showLunarCalendar ? 12 : 14, weight: isSelected ? .bold : .regular))
                    .foregroundColor(dayTextColor)

                if appSettings.showLunarCalendar {
                    Text(lunarText)
                        .font(.system(size: 7))
                        .foregroundColor(lunarTextColor)
                        .lineLimit(1)
                }

                let hasSystem = hasSystemEvents
                let hasUser = hasUserEvents
                let hasSubscription = hasSubscriptionEvents

                HStack(spacing: 3) {
                    if hasSystem {
                        Circle()
                            .fill(systemCalendarColor)
                            .frame(width: 5, height: 5)
                            .overlay(Circle().stroke(Color.white.opacity(0.8), lineWidth: 0.5))
                    }
                    if hasUser {
                        Circle()
                            .fill(accentColor)
                            .frame(width: 5, height: 5)
                            .overlay(Circle().stroke(Color.white.opacity(0.8), lineWidth: 0.5))
                    }
                    if hasSubscription {
                        Circle()
                            .fill(subscriptionCalendarColor)
                            .frame(width: 5, height: 5)
                            .overlay(Circle().stroke(Color.white.opacity(0.8), lineWidth: 0.5))
                    }
                }
            }
            .frame(height: 38)
            .frame(maxWidth: .infinity)
            .background(backgroundShape)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())

            // 休/班标记（右上角）
            if showRestMark || showWorkMark {
                VStack(spacing: 1) {
                    if showRestMark {
                        Text("休")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(isToday ? .white : accentColor)
                    }
                    if showWorkMark {
                        Text("班")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(isToday ? .white : .red)
                    }
                }
                .padding(.top, 1)
                .padding(.trailing, 2)
            }
        }
        // hover 弹出事件预览：内聚在单元格内（仅有事件时弹出）
        .background(
            GeometryReader { geo in
                CellPopoverPresenter(
                    isPresented: isHovered && !eventItems.isEmpty,
                    positioningRect: CGRect(origin: .zero, size: geo.size),
                    content: popoverContent
                )
            }
        )
        .onHover { hovered in
            isHovered = hovered
        }
    }

    // MARK: - Hover Popover

    private static let popoverDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    /// 事件预览弹出层内容（对齐系统日历排版：日期标题 + 色点 + 时间 + 标题；
    /// 内边距由 presenter 的 chrome 统一提供，此处不再加 padding）
    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Self.popoverDateFormatter.string(from: date))
                .font(.system(size: 13, weight: .semibold))
            ForEach(eventItems) { item in
                HStack(alignment: .top, spacing: 6) {
                    Circle()
                        .fill(popoverItemColor(for: item))
                        .frame(width: 7, height: 7)
                        .padding(.top, 3.5)
                    if let time = item.timeText {
                        Text(time)
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundColor(.secondary)
                            .frame(minWidth: 40, alignment: .leading)
                    }
                    Text(item.title)
                        .font(.system(size: 11))
                        .lineLimit(2)
                    // 智能跳过节假日标识：原休日任务当天静默跳过（语义 v3 无顺延）
                    if item.holidayMark == .skipped {
                        Text("已智能跳过")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                }
            }
        }
        .frame(minWidth: 140, alignment: .leading)
    }

    private func popoverItemColor(for item: CalendarEventItem) -> Color {
        switch item.category {
        case "用户": return accentColor
        case "系统": return systemCalendarColor
        case "订阅": return subscriptionCalendarColor
        default: return systemCalendarColor
        }
    }

    // MARK: - Colors

    private var dayTextColor: Color {
        if isToday { return .white }
        if isSelected { return accentColor }
        if !isCurrentMonth { return .secondary.opacity(0.4) }
        return .primary
    }

    private var lunarTextColor: Color {
        if isToday { return .white }
        if !isCurrentMonth { return .secondary.opacity(0.3) }
        return .secondary
    }

    @ViewBuilder
    private var backgroundShape: some View {
        if isToday {
            // 今天：主题色实心背景
            RoundedRectangle(cornerRadius: 6)
                .fill(accentColor)
        } else if isSelected && isImportant {
            // 选中+重要：半透明背景 + 边框
            RoundedRectangle(cornerRadius: 6)
                .stroke(accentColor, lineWidth: 1)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(accentColor.opacity(0.15))
                )
        } else if isSelected {
            // 选中（无重要标记）：主题色边框
            RoundedRectangle(cornerRadius: 6)
                .stroke(accentColor, lineWidth: 2)
        } else if isHovered && isImportant {
            // 重要日期 + hover：半透明背景 + 边框
            RoundedRectangle(cornerRadius: 6)
                .stroke(accentColor, lineWidth: 1)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(accentColor.opacity(0.15))
                )
        } else if isHovered {
            // 普通日期 hover：显示选中边框样式
            RoundedRectangle(cornerRadius: 6)
                .stroke(accentColor, lineWidth: 2)
        } else if isImportant {
            // 重要日期默认：仅半透明背景，无边框
            RoundedRectangle(cornerRadius: 6)
                .fill(accentColor.opacity(0.15))
        } else {
            Color.clear
        }
    }
}
