//
//  ReminderAlertView.swift
//  SwallowCalendar
//
//  待办事项提醒弹窗 - 自定义 SwiftUI 窗口（替代系统 NSAlert 样式）
//

import AppKit
import SwiftUI

// MARK: - 提醒弹窗窗口（borderless 圆角，支持成为 key 窗口以响应键盘）

final class ReminderAlertWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

// MARK: - 弹窗窗口控制器（生命周期与定位管理）

@MainActor
final class ReminderAlertWindowController {
    static let shared = ReminderAlertWindowController()

    private var window: ReminderAlertWindow?

    private init() {}

    /// 显示提醒弹窗（重复调用会替换已有窗口）
    func show(events: [CachedEvent], isExpired: Bool, onCompleteAll: @escaping () -> Void) {
        window?.close()

        // 宽 340 与主面板一致；高度由 SwiftUI 内容自适应（fittingSize），
        // 避免手工估算行高不准导致内容微溢出而出现多余滚动条。
        // 列表内部 maxHeight 封顶 5 项，超出由 ScrollView 滚动承接。
        let width: CGFloat = 340

        let rootView = ReminderAlertView(
            events: events,
            isExpired: isExpired,
            onDismiss: { [weak self] in self?.close() },
            onCompleteAll: { [weak self] in
                self?.close()
                onCompleteAll()
            }
        )

        let hostingView = NSHostingView(rootView: rootView.frame(width: width))
        let contentSize = hostingView.fittingSize

        let window = ReminderAlertWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = hostingView

        // 定位到屏幕右上角（与原 NSAlert 逻辑一致：上边距 20、右边距 20）
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        if let visibleFrame = screen?.visibleFrame {
            window.setFrameOrigin(NSPoint(
                x: visibleFrame.maxX - width - 20,
                y: visibleFrame.maxY - 20 - contentSize.height
            ))
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    func close() {
        window?.close()
        window = nil
    }
}

// MARK: - 弹窗内容视图

struct ReminderAlertView: View {
    let events: [CachedEvent]
    let isExpired: Bool
    let onDismiss: () -> Void
    let onCompleteAll: () -> Void

    @State private var accentColor: Color = Color(hex: AppSettings.shared.accentColorHex)

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            eventList
            Divider().opacity(0.5)
            footer
        }
        .background(
            VisualEffectView(material: .popover, blendingMode: .behindWindow)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        // Esc 键关闭弹窗
        .onExitCommand(perform: onDismiss)
    }

    /// 头部：状态图标 + 标题
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: isExpired ? "exclamationmark.circle.fill" : "bell.badge.fill")
                .font(.system(size: 22))
                .foregroundColor(isExpired ? .orange : accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(events.count) 个待办事项")
                    .font(.system(size: 14, weight: .semibold))
                Text(isExpired ? "已过期，请及时处理" : "即将到期")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    /// 事项列表：≤5 项用纯 VStack（高度精确、绝不出现滚动条）；
    /// >5 项用固定高度的 ScrollView 滚动查看
    @ViewBuilder
    private var eventList: some View {
        if events.count <= 5 {
            VStack(spacing: 6) {
                ForEach(events, id: \.eventID) { event in
                    eventRow(event)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        } else {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(events, id: \.eventID) { event in
                        eventRow(event)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            // 高度约 5 行卡片
            .frame(height: 290)
        }
    }

    /// 单条事项行：状态圆点 + 标题 + 时间
    private func eventRow(_ event: CachedEvent) -> some View {
        let isOverdue = (event.startDate ?? Date()) < Date()
        return HStack(spacing: 10) {
            Circle()
                .fill(isOverdue ? Color.orange : accentColor)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                if let startDate = event.startDate {
                    Text(Self.dateFormatter.string(from: startDate))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.05))
        )
    }

    /// 底部按钮区：次要（知道了）+ 主要（全部标记完成）
    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()

            Button {
                onDismiss()
            } label: {
                Text("知道了")
                    .font(.system(size: 12))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill(Color.primary.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)

            Button {
                onCompleteAll()
            } label: {
                Text("全部标记完成")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill(accentColor)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}
