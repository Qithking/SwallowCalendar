//
//  ReminderAlertService.swift
//  SwallowCalendar
//
//  待办事项到期提醒服务
//

import Foundation
@preconcurrency import AppKit
import SwiftData
import os
import SwiftUI  // 为了导入 CalendarEvent

@MainActor
final class ReminderAlertService {
    static let shared = ReminderAlertService()
    
    private var timer: Timer?
    private var lastAlertedEventIDs: [String] = []
    /// 持久化已提醒事件ID的 UserDefaults 键
    private static let alertedEventIDsKey = "ReminderAlertService.lastAlertedEventIDs"
    /// 已提醒事件ID的最大缓存数量
    private let maxAlertedEventIDs = 1000
    
    private init() {
        // 从 UserDefaults 恢复已提醒事件ID，避免应用重启后重复弹窗
        if let saved = UserDefaults.standard.stringArray(forKey: Self.alertedEventIDsKey) {
            self.lastAlertedEventIDs = saved
        }
    }
    
    /// 配置服务
    func configure(with container: ModelContainer) {
        // modelContainer 已不再需要，保留方法以兼容调用方
    }
    
    /// 启动提醒检查
    func startMonitoring() {
        stopMonitoring()
        
        // 确保在主线程上执行检查
        DispatchQueue.main.async { [weak self] in
            // 不要立即检查过期事项，等待数据同步完成后由外部调用 checkExpiredEvents()
            // 每分钟检查一次是否有待办事项到期
            self?.timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task {
                    await self?.checkDueEvents()
                }
            }
        }
    }
    
    /// 检查过期事项（供数据同步完成后调用）
    /// 启动时的检查会忽略 lastAlertedEventIDs 过滤，确保过期事项始终被提示
    func checkExpiredEvents() async {
        AppLogger.reminder.info("[DEBUG-r1] STARTUP-CHECK-BEGIN at=\(Date().timeIntervalSince1970)")
        await checkDueEvents(includeExpired: true, ignoreAlertedCache: true)
        AppLogger.reminder.info("数据同步后过期事项检查完成")
    }
    
    /// 停止提醒检查
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }
    
    /// 检查到期的待办事项
    /// - Parameters:
    ///   - includeExpired: 是否包含已过期的事项（仅在应用启动时使用）
    ///   - ignoreAlertedCache: 是否忽略已提醒缓存（启动时为 true，确保过期事项始终提示）
    private func checkDueEvents(includeExpired: Bool = false, ignoreAlertedCache: Bool = false) async {
        // 使用 EventCacheService 的上下文，确保与待办列表显示的数据一致
        guard let context = EventCacheService.shared.context else {
            AppLogger.reminder.warning("EventCacheService 未配置")
            return
        }
        let now = Date()
        let calendar = Calendar.current
        
        // 先获取所有未完成的用户事件，然后在内存中过滤日期
        // 这种方式可以避免 SwiftData Predicate 的复杂语法问题
        // EventCategory.user.rawValue 的值是 "用户"（中文字符串）
        let userCategory = "用户"
        let baseDescriptor = FetchDescriptor<CachedEvent>(
            predicate: #Predicate {
                $0.categoryRaw == userCategory &&
                !$0.isCompleted &&
                $0.startDate != nil
            },
            sortBy: [SortDescriptor(\.startDate)]
        )
        
        do {
            let allUserEvents = try context.fetch(baseDescriptor)
            
            // 在内存中过滤日期范围
            let dueEvents = allUserEvents.filter { event in
                guard let startDate = event.startDate else { return false }

                if includeExpired {
                    // 启动时的过期检查：
                    // - 设置了提醒的事项：提醒时间已过（startDate - reminderMinutes <= now）
                    // - 未设置提醒的事项：事件已过期（startDate < now）
                    if event.reminderMinutes > 0 {
                        let alertTime = startDate.addingTimeInterval(TimeInterval(-event.reminderMinutes * 60))
                        return alertTime <= now
                    } else {
                        return startDate < now
                    }
                } else {
                    // 常规定时检查：按照用户设置的提醒时间触发
                    // 未设置提醒（reminderMinutes == 0）的事项不弹窗
                    guard event.reminderMinutes > 0 else { return false }
                    let alertTime = startDate.addingTimeInterval(TimeInterval(-event.reminderMinutes * 60))
                    // 提醒时间已到达，且事件尚未过期（避免重复提醒已过期事项）
                    // 窗口设为 90 秒，配合 60 秒定时器确保不遗漏
                    let windowStart = calendar.date(byAdding: .second, value: -90, to: now)!
                    return alertTime <= now && alertTime >= windowStart
                }
            }
            
            // 过滤掉已经提醒过的事件（启动时忽略缓存，确保过期事项始终提示）
            let newEvents = ignoreAlertedCache ? dueEvents : dueEvents.filter { !lastAlertedEventIDs.contains($0.eventID) }
            
            if newEvents.count > 0 {
                for event in newEvents {
                    AppLogger.reminder.info("[DEBUG-r1] STARTUP-POP id=\(event.eventID, privacy: .public) title=\(event.title, privacy: .public) cacheCompleted=false start=\(event.startDate.map { String($0.timeIntervalSince1970) } ?? "nil", privacy: .public) reminderMinutes=\(event.reminderMinutes) isReminder=\(event.isReminder)")
                }
                // 合并显示所有到期/即将到期的事项
                let isExpired = includeExpired || newEvents.allSatisfy { ($0.startDate ?? now) < now }
                showCombinedAlert(for: newEvents, isExpired: isExpired)
                // 记录已提醒的事件ID（追加到末尾，保持插入顺序）
                newEvents.forEach { event in
                    if !lastAlertedEventIDs.contains(event.eventID) {
                        lastAlertedEventIDs.append(event.eventID)
                    }
                }
                // 持久化到 UserDefaults，避免应用重启后重复弹窗
                persistAlertedEventIDs()
                // 限制数组大小，避免内存泄漏
                trimAlertedEventIDsIfNeeded()
                // 5分钟后允许再次提醒
                DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in
                    newEvents.forEach { event in
                        self?.lastAlertedEventIDs.removeAll { $0 == event.eventID }
                    }
                }
            }
        } catch {
            AppLogger.reminder.error("检查到期事件失败: \(String(describing: error), privacy: .public)")
        }
    }
    
    /// 显示合并的过期事项提醒弹窗
    private func showCombinedAlert(for events: [CachedEvent], isExpired: Bool) {
        // 激活应用
        NSApp.activate(ignoringOtherApps: true)
        
        let alert = NSAlert()
        alert.messageText = "\(events.count) 个待办事项\(isExpired ? "已过期" : "即将到期")"
        alert.alertStyle = isExpired ? .warning : .informational
        
        // 构建事项列表文本
        let itemsList = events.enumerated().map { index, event in
            let dateText = formatDate(event.startDate)
            return "\(index + 1). \(event.title)\n   \(dateText)"
        }.joined(separator: "\n\n")
        
        // 使用 NSScrollView 限制内容最大高度 500px，超出显示滚动条
        let contentWidth: CGFloat = 380
        let font = NSFont.systemFont(ofSize: 13)
        
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: 40))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.defaultParagraphStyle = {
            let ps = NSMutableParagraphStyle()
            ps.lineBreakMode = .byWordWrapping
            return ps
        }()
        textView.textColor = .textColor
        textView.font = font
        textView.string = itemsList
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: contentWidth - 20, height: .greatestFiniteMagnitude)
        textView.sizeToFit()
        
        let textHeight = max(textView.frame.height, 40)
        let contentHeight = min(textHeight, 350)
        
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight)
        
        alert.accessoryView = scrollView
        
        alert.addButton(withTitle: "知道了")
        alert.addButton(withTitle: "全部标记完成")
        
        // 确定目标屏幕
        var targetScreen: NSScreen?
        
        if let activeWindow = NSApp.keyWindow {
            targetScreen = activeWindow.screen
        }
        if targetScreen == nil {
            targetScreen = NSScreen.main ?? NSScreen.screens.first
        }
        
        // NSAlert.runModal() 内部会强制将窗口居中显示，
        // 在 runModal() 之前设置位置都会被覆盖。
        // 因此先隐藏窗口(alpha=0)，等 runModal() 居中并完成布局后，
        // didBecomeKeyNotification 触发时窗口尺寸已准确，
        // 此时移动到右上角再显示(alpha=1)，用户不会看到居中闪现。
        if let screen = targetScreen {
            let screenFrame = screen.visibleFrame
            let window = alert.window
            window.alphaValue = 0
            // 使用 using: 参数避免在 @Sendable 闭包中捕获可变变量
            let observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak window] _ in
                guard let window = window else { return }
                let size = window.frame.size
                window.setFrameTopLeftPoint(NSPoint(
                    x: screenFrame.maxX - size.width - 20,
                    y: screenFrame.maxY - 20
                ))
                window.alphaValue = 1
            }
            // runModal 返回后移除 observer
            DispatchQueue.main.async {
                NotificationCenter.default.removeObserver(observer)
            }
        }
        
        let response = alert.runModal()
        
        if response == .alertSecondButtonReturn {
            // 用户点击"全部标记完成"
            events.forEach { markAsCompleted(eventID: $0.eventID) }
        }
    }
    
    /// 标记事件为完成
    private func markAsCompleted(eventID: String) {
        // 使用 EventCacheService 的统一上下文，确保与 @Query 同步
        guard let context = EventCacheService.shared.context else { return }

        let descriptor = FetchDescriptor<CachedEvent>(
            predicate: #Predicate { $0.eventID == eventID }
        )

        do {
            if let event = try context.fetch(descriptor).first {
                // 使用 CalendarService 的双向同步方法（同时更新 EventKit 和 SwiftData）
                CalendarService.shared.toggleEventCompleted(
                    eventID: eventID,
                    isCompleted: true,
                    isReminder: event.isReminder
                )
                AppLogger.reminder.info("已标记事件完成: \(eventID)")
            }
        } catch {
            AppLogger.reminder.error("标记完成失败: \(String(describing: error), privacy: .public)")
        }
    }
    
    /// 格式化日期显示（统一格式：yyyy/MM/dd HH:mm）
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter
    }()
    
    private func formatDate(_ date: Date?) -> String {
        guard let date = date else { return "" }
        return Self.dateFormatter.string(from: date)
    }
    
    /// 将已提醒事件ID持久化到 UserDefaults
    private func persistAlertedEventIDs() {
        UserDefaults.standard.set(lastAlertedEventIDs, forKey: Self.alertedEventIDsKey)
    }

    /// 限制 lastAlertedEventIDs 的大小，避免内存泄漏
    /// 淘汰最早添加的记录（数组头部），保留最近的记录（数组尾部）
    private func trimAlertedEventIDsIfNeeded() {
        if lastAlertedEventIDs.count > maxAlertedEventIDs {
            let overflow = lastAlertedEventIDs.count - maxAlertedEventIDs
            lastAlertedEventIDs.removeFirst(overflow)
            AppLogger.reminder.info("清理了 \(overflow) 个过期提醒记录")
        }
        persistAlertedEventIDs()
    }
    
    /// 清除已提醒记录（用于重置）
    func clearAlertHistory() {
        lastAlertedEventIDs.removeAll()
        persistAlertedEventIDs()
    }
}