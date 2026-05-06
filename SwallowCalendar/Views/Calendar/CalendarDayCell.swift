//
//  CalendarDayCell.swift
//  SwallowCalendar
//

import SwiftUI
import EventKit

/// 日历单元格中事件条目的统一数据结构，确保标题、颜色、分类三者始终对齐
struct CalendarEventItem: Identifiable {
    let id = UUID()
    let title: String
    let colorHex: String
    let category: String  // "系统" | "订阅" | "用户"
}

struct CalendarDayCell: View {
    @Environment(AppSettings.self) private var appSettings
    let date: Date
    let isSelected: Bool
    let isToday: Bool
    let isCurrentMonth: Bool
    let lunarText: String
    let isHovered: Bool
    var eventItems: [CalendarEventItem] = []  // 事件条目数组，标题/颜色/分类一一对应
    var systemCalendarColor: Color = Color(hex: "#007AFF")
    var subscriptionCalendarColor: Color = Color(hex: "#FF9500")
    var isImportant: Bool = false
    
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
    
    /// 是否显示"休"标记（标题包含"假期"或"（休）"）
    private var showRestMark: Bool {
        eventItems.contains { $0.title.contains("假期") || $0.title.contains("（休）") }
    }
    
    /// 是否显示"班"标记（标题包含"补班"或"（班）"）
    private var showWorkMark: Bool {
        eventItems.contains { $0.title.contains("补班") || $0.title.contains("（班）") }
    }

    @State private var accentColor: Color = Color(hex: AppSettings.shared.accentColorHex)

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
            .onChange(of: appSettings.accentColorHex) { _, newColor in
                accentColor = Color(hex: newColor)
            }

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
