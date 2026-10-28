//
//  ReminderAlertView.swift
//  SwallowCalendar
//
//  待办事项提醒弹窗 - 自定义 SwiftUI 窗口（替代系统 NSAlert 样式）
//

import AppKit
import SwiftUI

// MARK: - 提醒弹窗窗口（borderless 圆角，支持成为 key 窗口以响应键盘）

// E-12：NSWindow 本身主线程隔离，显式标注对齐类型系统保证
@MainActor
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
    /// G4：onEventComplete 单条完成回调、onSnooze 稍后提醒回调（10/30/60 分钟）
    func show(
        events: [CachedEvent],
        isExpired: Bool,
        onCompleteAll: @escaping () -> Void,
        onEventComplete: @escaping (String) -> Void = { _ in },
        onSnooze: @escaping (String, Int) -> Void = { _, _ in }
    ) {
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
            },
            onEventComplete: { eventID in
                onEventComplete(eventID)
            },
            onSnooze: { eventID, minutes in
                onSnooze(eventID, minutes)
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
        // V-26：固定用主屏——keyWindow 可能是即将关闭的弹窗自身，会导致定位漂移
        let screen = NSScreen.main ?? NSScreen.screens.first
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
    /// C2：单条完成回调（eventID）
    let onEventComplete: (String) -> Void
    /// C2：稍后提醒回调（eventID, minutes）
    let onSnooze: (String, Int) -> Void

    /// 单条完成/稍后提醒后从弹窗移除该行（其余保留，全部移除后自动关闭）
    @State private var displayedEvents: [CachedEvent]

    init(
        events: [CachedEvent],
        isExpired: Bool,
        onDismiss: @escaping () -> Void,
        onCompleteAll: @escaping () -> Void,
        onEventComplete: @escaping (String) -> Void,
        onSnooze: @escaping (String, Int) -> Void
    ) {
        self.events = events
        self.isExpired = isExpired
        self.onDismiss = onDismiss
        self.onCompleteAll = onCompleteAll
        self.onEventComplete = onEventComplete
        self.onSnooze = onSnooze
        // 过期待办按「过期时间」降序展示（最近过期的在最上面）：
        // 过期时刻 = startDate − 最大提醒提前量（expiryTime），非 startDate 本身
        _displayedEvents = State(initialValue: events.sorted {
            ($0.expiryTime ?? .distantPast) > ($1.expiryTime ?? .distantPast)
        })
    }

    // V-18：直接读共享设置的主题色（弹窗为独立窗口，无 appSettings 环境可注入）
    private var accentColor: Color { Color(hex: AppSettings.shared.accentColorHex) }

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
        // 4 视图同步：显示期间别处完成/编辑后重查快照，已完成/已删除行移除，
        // 全部移除后自动关闭（与 removeRow 同语义）
        .onReceive(NotificationCenter.default.publisher(for: .cachedEventsChanged)) { _ in
            guard let context = EventCacheService.shared.context else { return }
            displayedEvents = ReminderAlertService.refreshedDisplayRows(
                events: displayedEvents,
                context: context
            )
            if displayedEvents.isEmpty {
                onDismiss()
            }
        }
    }

    /// 头部：状态图标 + 标题
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: isExpired ? "exclamationmark.circle.fill" : "bell.badge.fill")
                .font(.system(size: 22))
                .foregroundColor(isExpired ? .orange : accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(displayedEvents.count) 个待办事项")
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
        if displayedEvents.count <= 5 {
            VStack(spacing: 6) {
                ForEach(displayedEvents, id: \.eventID) { event in
                    eventRow(event)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        } else {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(displayedEvents, id: \.eventID) { event in
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

    /// 单条事项行：状态圆点 + 标题 + 时间 + 行内操作（稍后提醒菜单 / 单条完成）
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
            // 稍后提醒菜单（10/30/60 分钟，复用 60s 轮询触发）
            Menu {
                ForEach([10, 30, 60], id: \.self) { minutes in
                    Button("稍后 \(minutes) 分钟") {
                        removeRow(event)
                        onSnooze(event.eventID, minutes)
                    }
                }
            } label: {
                Image(systemName: "clock")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("稍后提醒")
            // 单条完成：事项变已办并从弹窗移除，其余保留（AC-4）
            Button {
                removeRow(event)
                onEventComplete(event.eventID)
            } label: {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 13))
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
            .help("标记完成")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.05))
        )
    }

    /// 从弹窗移除一行；全部移除后自动关闭
    private func removeRow(_ event: CachedEvent) {
        displayedEvents.removeAll { $0.eventID == event.eventID }
        if displayedEvents.isEmpty {
            onDismiss()
        }
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
