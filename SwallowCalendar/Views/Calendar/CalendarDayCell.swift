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

    @State private var showPopover = false
    @State private var accentColor: Color = Color(hex: AppSettings.shared.accentColorHex)

    var body: some View {
        VStack(spacing: 1) {
            // 公历日期
            Text("\(Calendar.current.component(.day, from: date))")
                .font(.system(size: 12, weight: isSelected ? .bold : .regular))
                .foregroundColor(dayTextColor)

                // 农历/订阅事件
                if appSettings.showLunarCalendar {
                    Text(subscriptionTitles.first ?? lunarText)
                        .font(.system(size: 7))
                        .foregroundColor(subscriptionTextColor)
                        .lineLimit(1)
                } else if !subscriptionTitles.isEmpty {
                    Text(subscriptionTitles.first ?? "")
                        .font(.system(size: 7))
                        .foregroundColor(subscriptionTextColor)
                        .lineLimit(1)
            } else {
                Text("")
                    .font(.system(size: 7))
                    .lineLimit(1)
            }

            // 事件标记
            if eventCount > 0 {
                Circle()
                    .fill(accentColor)
                    .frame(width: 3, height: 3)
            }
        }
        .frame(height: 38)
        .frame(maxWidth: .infinity)
        .background(backgroundShape)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hovering in
            if hasPopoverContent {
                showPopover = hovering
            }
        }
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            popoverContent
        }
        .onChange(of: appSettings.accentColorHex) { _, newColor in
            accentColor = Color(hex: newColor)
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
                            .fill(.red)
                            .frame(width: 6, height: 6)
                        Text(name)
                            .font(.system(size: 11))
                    }
                }
            }

            // 事件（去重，保持顺序）
            let uniqueEvents = eventTitles.uniqued()
            if !uniqueEvents.isEmpty {
                ForEach(Array(uniqueEvents.enumerated()), id: \.offset) { _, title in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(accentColor)
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

    private var subscriptionTextColor: Color {
        if !isCurrentMonth { return .secondary.opacity(0.3) }
        if !subscriptionTitles.isEmpty { return .red }
        return .secondary
    }

    @ViewBuilder
    private var backgroundShape: some View {
        if isToday {
            // 今天：主题色实心背景
            RoundedRectangle(cornerRadius: 6)
                .fill(accentColor)
        } else if isSelected {
            // 选中日期：只有边框，无填充
            RoundedRectangle(cornerRadius: 6)
                .stroke(accentColor, lineWidth: 2)
        } else if isHovered {
            RoundedRectangle(cornerRadius: 6)
                .fill(accentColor.opacity(0.1))
        } else if eventCount > 1 {
            // 多事件日期使用第一个事件的颜色作为背景提示
            if let firstColorHex = eventColors.first {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(hex: firstColorHex).opacity(0.5), lineWidth: 1)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
            }
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
