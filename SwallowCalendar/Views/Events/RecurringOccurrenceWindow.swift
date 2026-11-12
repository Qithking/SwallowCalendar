//
//  RecurringOccurrenceWindow.swift
//  SwallowCalendar
//
//  循环任务「查看更多待办」独立窗口：分页展示未来 occurrence 序列
//  （待办列表只显示下一条，未来序列在此按页加载，避免大窗口展开卡死）

import SwiftUI
import AppKit

@MainActor
final class RecurringOccurrenceWindowManager {
    static let shared = RecurringOccurrenceWindowManager()
    private var window: NSWindow?

    private init() {}

    /// 打开某循环任务的未来待办分页窗口（eventID 用于回查 base 本体行）
    func open(eventID: String, title: String) {
        window?.close()
        window = nil
        guard let base = EventCacheService.shared.baseEvent(withID: eventID),
              base.isRecurringActive else { return }

        let content = RecurringOccurrenceListView(base: base)
        let hosting = NSHostingView(rootView: content.frame(minWidth: 280, minHeight: 200))

        // 透明玻璃窗口：与修改事项窗口同款装配（GlassWindowChrome 统一标题栏拖动区）
        let win = GlassWindowChrome.makeWindow(
            title: "待办日程 - \(title)",
            contentSize: NSSize(width: 320, height: 340)
        )
        GlassWindowChrome.installContentView(on: win, hostingView: hosting)
        win.isReleasedWhenClosed = false
        win.center()
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// 循环任务未来待办分页视图：最大高度区滚动展示，点「更多」加载下一页
private struct RecurringOccurrenceListView: View {
    let base: CachedEvent
    @State private var occurrences: [Date] = []
    @State private var hasMore = true
    private let pageSize = 10

    var body: some View {
        // 与修改事项窗口同款：玻璃材质底铺满整窗（含标题栏），否则透明窗口桌面直透
        ZStack {
            VisualEffectView()
                .ignoresSafeArea()

            listBody
        }
    }

    private var listBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if occurrences.isEmpty {
                Spacer()
                Text("暂无更多待办日程")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                // 待办显示区域：最大高度 + 超出滚动
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(occurrences.enumerated()), id: \.offset) { _, date in
                            Text(Self.text(for: date, isAllDay: base.isAllDay))
                                .font(.system(size: 12))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 3)
                                .padding(.horizontal, 8)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 260)
            }

            if hasMore {
                HStack {
                    Spacer()
                    Button("更多") {
                        loadNextPage()
                    }
                    .controlSize(.small)
                    Spacer()
                }
                .padding(.vertical, 6)
            }
        }
        .padding(.top, 6)
        .onAppear {
            if occurrences.isEmpty {
                loadNextPage()
            }
        }
    }

    private func loadNextPage() {
        let batch = EventCacheService.futureOccurrenceDates(of: base, skip: occurrences.count, limit: pageSize)
        occurrences.append(contentsOf: batch)
        if batch.count < pageSize {
            hasMore = false
        }
    }

    private static func text(for date: Date, isAllDay: Bool) -> String {
        isAllDay ? dateFormatter.string(from: date) : dateTimeFormatter.string(from: date)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日"
        return f
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日 HH:mm"
        return f
    }()
}