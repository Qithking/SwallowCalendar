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
    let holidayNames: [String]
    let eventCount: Int
    let isHovered: Bool
    var eventTitles: [String] = []
    var eventColors: [String] = []

    @State private var showPopover = false

    var body: some View {
        VStack(spacing: 1) {
            // 公历日期
            Text("\(Calendar.current.component(.day, from: date))")
                .font(.system(size: 12, weight: isSelected ? .bold : .regular))
                .foregroundColor(dayTextColor)

            // 农历/节假日
            if appSettings.showLunarCalendar {
                Text(holidayNames.first ?? lunarText)
                    .font(.system(size: 7))
                    .foregroundColor(holidayTextColor)
                    .lineLimit(1)
            } else if !holidayNames.isEmpty {
                Text(holidayNames.first ?? "")
                    .font(.system(size: 7))
                    .foregroundColor(holidayTextColor)
                    .lineLimit(1)
            } else {
                Text("")
                    .font(.system(size: 7))
                    .lineLimit(1)
            }

            // 事件标记
            if eventCount > 0 {
                Circle()
                    .fill(Color.accentColor)
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
    }

    // MARK: - Popover

    private var hasPopoverContent: Bool {
        !holidayNames.isEmpty || !eventTitles.isEmpty
    }

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 日期标题
            Text(dateString)
                .font(.system(size: 12, weight: .semibold))

            // 节假日（去重，保持顺序）
            let uniqueHolidays = holidayNames.uniqued()
            if !uniqueHolidays.isEmpty {
                ForEach(Array(uniqueHolidays.enumerated()), id: \.offset) { _, name in
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
                            .fill(Color.accentColor)
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
        if isSelected { return .white }
        if isToday { return .accentColor }
        if !isCurrentMonth { return .secondary.opacity(0.4) }
        return .primary
    }

    private var holidayTextColor: Color {
        if !isCurrentMonth { return .secondary.opacity(0.3) }
        if !holidayNames.isEmpty { return .red }
        return .secondary
    }

    @ViewBuilder
    private var backgroundShape: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor)
        } else if isHovered {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(0.1))
        } else if isToday {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor)
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
