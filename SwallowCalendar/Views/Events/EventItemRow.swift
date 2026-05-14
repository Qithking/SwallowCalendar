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
    /// 是否启用倒计时刷新
    private let enableCountdownRefresh: Bool
    
    /// 倒计时管理器
    @ObservedObject private var timerManager: CountdownTimerManager

    @Environment(AppSettings.self) private var appSettings
    @State private var isHovered = false

    init(
        event: CalendarEvent,
        onEdit: ((CalendarEvent) -> Void)? = nil,
        onDelete: ((CalendarEvent) -> Void)? = nil,
        onComplete: ((CalendarEvent) -> Void)? = nil,
        onUncomplete: ((CalendarEvent) -> Void)? = nil,
        isOverdue: Bool = false,
        timerManager: CountdownTimerManager? = nil
    ) {
        self.event = event
        self.onEdit = onEdit
        self.onDelete = onDelete
        self.onComplete = onComplete
        self.onUncomplete = onUncomplete
        self.isOverdue = isOverdue
        self.enableCountdownRefresh = timerManager != nil
        self.timerManager = timerManager ?? CountdownTimerManager.shared
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
        .onAppear {
            // 标记为可见，接收倒计时刷新
            if enableCountdownRefresh && event.needsDynamicCountdown {
                timerManager.markVisible(eventID: event.id)
            }
        }
        .onDisappear {
            // 标记为不可见，停止接收倒计时刷新
            if enableCountdownRefresh && event.needsDynamicCountdown {
                timerManager.markInvisible(eventID: event.id)
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

    /// 带主题色背景的倒计时标签
    private var countdownBorderedView: some View {
        Text(event.countdownText)
            .id(enableCountdownRefresh && timerManager.shouldRefresh(eventID: event.id) ? "\(event.id)-\(timerManager.refreshTrigger)" : event.id)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(hex: appSettings.accentColorHex))
            )
    }

    private var formattedDate: String {
        guard let start = event.startDate else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"
        return formatter.string(from: start)
    }

    private var formattedDateTime: String {
        guard let start = event.startDate else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
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
