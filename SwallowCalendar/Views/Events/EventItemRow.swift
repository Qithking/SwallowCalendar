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

            // 日历颜色标识
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(hex: event.calendarColorHex))
                .frame(width: 3, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if isOverdue {
                        Text("已过期")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.red)
                    }
                    Text(event.title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .strikethrough(event.isCompleted, color: .secondary)
                        .foregroundColor(event.isCompleted ? .secondary : .primary)
                }

                HStack(spacing: 4) {
                    if event.hasTime {
                        Text(event.startDate ?? Date(), style: .time)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)

                        if !isOverdue {
                            Text(event.countdownText)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(countdownColor)
                        }
                    } else {
                        Text(formattedDate)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            // 悬停时显示操作按钮
            if isHovered && !event.isCompleted {
                HStack(spacing: 4) {
                    if onEdit != nil {
                        Button {
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
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }

    private var countdownColor: Color {
        guard let start = event.startDate else { return .secondary }
        let hours = start.timeIntervalSinceNow / 3600
        if hours < 1 { return .red }
        if hours < 24 { return .orange }
        return .secondary
    }

    private var formattedDate: String {
        guard let start = event.startDate else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter.string(from: start)
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
