//
//  CalendarDayCell.swift
//  SwallowCalendar
//

import SwiftUI
import EventKit

struct CalendarDayCell: View {
    @Environment(AppSettings.self) private var appSettings
    let date: Date
    let isSelected: Bool
    let isToday: Bool
    let isCurrentMonth: Bool
    let lunarText: String
    let subscriptionTitles: [String]
    let eventCount: Int
    let isHovered: Bool
    var eventTitles: [String] = []
    var eventColors: [String] = []
    var eventCategories: [String] = []  // 事件分类，用于判断是否为用户分类
    var systemCalendarColor: Color = Color(hex: "#007AFF")
    var subscriptionCalendarColor: Color = Color(hex: "#FF9500")
    var isImportant: Bool = false
    
    /// 计算属性：判断是否有系统日历事件（非订阅、非用户）
    private var hasSystemEvents: Bool {
        if !eventCategories.isEmpty {
            return eventCategories.contains { $0 == "系统" }
        }
        return eventCount > 0
    }
    
    /// 计算属性：判断是否有用户事件
    private var hasUserEvents: Bool {
        eventCategories.contains { $0 == "用户" }
    }
    
    /// 计算属性：判断是否有订阅事件
    private var hasSubscriptionEvents: Bool {
        !subscriptionTitles.isEmpty
    }
    
    /// 获取事件对应的颜色
    private func eventColor(for index: Int) -> Color {
        // 如果是用户分类，使用主题色
        if index < eventCategories.count && eventCategories[index] == "用户" {
            return accentColor
        }
        if index < eventColors.count {
            let color = Color(hex: eventColors[index])
            return color
        }
        return systemCalendarColor
    }

    // MARK: - Holiday/Work Marks
    
    /// 是否显示"休"标记（标题包含"假期"或"（休）"）
    private var showRestMark: Bool {
        let allTitles = subscriptionTitles + eventTitles
        return allTitles.contains { title in
            title.contains("假期") || title.contains("（休）")
        }
    }
    
    /// 是否显示"班"标记（标题包含"补班"或"（班）"）
    private var showWorkMark: Bool {
        let allTitles = subscriptionTitles + eventTitles
        return allTitles.contains { title in
            title.contains("补班") || title.contains("（班）")
        }
    }

    @State private var showPopover = false
    @State private var isHovering = false
    @State private var accentColor: Color = Color(hex: AppSettings.shared.accentColorHex)

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 1) {
                // 公历日期
                Text("\(Calendar.current.component(.day, from: date))")
                    .font(.system(size: appSettings.showLunarCalendar ? 12 : 14, weight: isSelected ? .bold : .regular))
                    .foregroundColor(dayTextColor)

                // 农历（仅显示农历，不显示订阅事件名称）
                if appSettings.showLunarCalendar {
                    Text(lunarText)
                        .font(.system(size: 7))
                        .foregroundColor(lunarTextColor)
                        .lineLimit(1)
                }

                // 事件标记 - 按照分类显示小圆点，最多3个
                let hasSystem = hasSystemEvents
                let hasUser = hasUserEvents
                let hasSubscription = hasSubscriptionEvents
                
                HStack(spacing: 3) {
                    // 系统日历事件小圆点
                    if hasSystem {
                        Circle()
                            .fill(systemCalendarColor)
                            .frame(width: 5, height: 5)
                            .overlay(Circle().stroke(Color.white.opacity(0.8), lineWidth: 0.5))
                    }
                    // 用户事件小圆点（主题色）
                    if hasUser {
                        Circle()
                            .fill(accentColor)
                            .frame(width: 5, height: 5)
                            .overlay(Circle().stroke(Color.white.opacity(0.8), lineWidth: 0.5))
                    }
                    // 订阅日历事件小圆点
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
            .onHover { hovering in
                isHovering = hovering
                if hovering && hasPopoverContent {
                    showPopover = true
                } else if !hovering {
                    showPopover = false
                }
            }
            .popover(isPresented: $showPopover, arrowEdge: .bottom) {
                popoverContent
            }
            // 数据变化时若不再有内容则关闭 popover
            .onChange(of: hasPopoverContent) { _, newValue in
                if !newValue {
                    showPopover = false
                }
            }
            .onChange(of: appSettings.accentColorHex) { _, newColor in
                accentColor = Color(hex: newColor)
            }

            // 休/班标记（右上角）
            if showRestMark || showWorkMark {
                VStack(spacing: 1) {
                    if showRestMark {
                        Text("休")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(Color(hex: "#2E8B57")) // 深绿色
                    }
                    if showWorkMark {
                        Text("班")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.red)
                    }
                }
                .padding(.top, 1)
                .padding(.trailing, 2)
            }
        }
    }

    // MARK: - Popover

    private var hasPopoverContent: Bool {
        !subscriptionTitles.isEmpty || !eventTitles.isEmpty
    }

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 日期标题
            Text(dateString)
                .font(.system(size: 12, weight: .semibold))

            // 订阅事件（去重，保持顺序）
            let uniqueSubscriptions = subscriptionTitles.uniqued()
            if !uniqueSubscriptions.isEmpty {
                ForEach(Array(uniqueSubscriptions.enumerated()), id: \.offset) { _, name in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(subscriptionCalendarColor)
                            .frame(width: 6, height: 6)
                        Text(name)
                            .font(.system(size: 11))
                    }
                }
            }

            // 事件（按照分类显示颜色，与日期下方一致）
            if !eventTitles.isEmpty {
                ForEach(Array(eventTitles.enumerated()), id: \.offset) { index, title in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(popoverEventColor(for: index))
                            .frame(width: 6, height: 6)
                        Text(title)
                            .font(.system(size: 11))
                            .lineLimit(2)
                    }
                }
            }
        }
        .padding(10)
        .frame(minWidth: 140)
    }
    
    /// 获取 popover 中事件对应的颜色（按照分类显示，与日期下方一致）
    private func popoverEventColor(for index: Int) -> Color {
        // 根据事件分类返回对应颜色
        if index < eventCategories.count {
            let category = eventCategories[index]
            if category == "用户" {
                return accentColor  // 用户分类使用主题色
            } else if category == "系统" {
                return systemCalendarColor  // 系统日历使用设置的颜色
            } else if category == "订阅" {
                return subscriptionCalendarColor  // 订阅日历使用设置的颜色
            }
        }
        // 默认返回系统日历颜色
        return systemCalendarColor
    }

    private var dateString: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
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

// MARK: - Array Deduplication

extension Array where Element: Equatable & Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
