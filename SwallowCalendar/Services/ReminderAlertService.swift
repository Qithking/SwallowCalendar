//
//  ReminderAlertService.swift
//  SwallowCalendar
//
//  待办事项到期提醒服务
//

import Foundation
import AppKit
import SwiftData
import SwiftUI  // 为了导入 CalendarEvent

@MainActor
final class ReminderAlertService {
    static let shared = ReminderAlertService()
    
    private var timer: Timer?
    private var lastAlertedEventIDs: Set<String> = []
    private var modelContainer: ModelContainer?
    /// 已提醒事件ID的最大缓存数量
    private let maxAlertedEventIDs = 1000
    
    private init() {}
    
    /// 配置服务
    func configure(with container: ModelContainer) {
        self.modelContainer = container
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
    func checkExpiredEvents() async {
        await checkDueEvents(includeExpired: true)
        print("[ReminderAlertService] 数据同步后过期事项检查完成")
    }
    
    /// 停止提醒检查
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }
    
    /// 检查到期的待办事项
    /// - Parameter includeExpired: 是否包含已过期的事项（仅在应用启动时使用）
    private func checkDueEvents(includeExpired: Bool = false) async {
        // 使用 EventCacheService 的上下文，确保与待办列表显示的数据一致
        guard let context = EventCacheService.shared.context else {
            print("[ReminderAlertService] EventCacheService 未配置")
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
                    return startDate < now
                } else {
                    let startOfWindow = calendar.date(byAdding: .minute, value: -5, to: now)!
                    let endOfWindow = calendar.date(byAdding: .minute, value: 5, to: now)!
                    return startDate >= startOfWindow && startDate <= endOfWindow
                }
            }
            
            // 过滤掉已经提醒过的事件
            let newEvents = dueEvents.filter { !lastAlertedEventIDs.contains($0.eventID) }
            
            if newEvents.count > 0 {
                // 合并显示所有到期/即将到期的事项
                let isExpired = includeExpired || newEvents.allSatisfy { ($0.startDate ?? now) < now }
                showCombinedAlert(for: newEvents, isExpired: isExpired)
                // 记录已提醒的事件ID
                newEvents.forEach { lastAlertedEventIDs.insert($0.eventID) }
                // 限制 Set 大小，避免内存泄漏
                trimAlertedEventIDsIfNeeded()
                // 5分钟后允许再次提醒
                DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in
                    newEvents.forEach { self?.lastAlertedEventIDs.remove($0.eventID) }
                }
            }
        } catch {
            print("[ReminderAlertService] 检查到期事件失败: \(error)")
        }
    }
    
    /// 显示到期提醒弹窗
    /// - Parameter isExpired: 是否为已过期事项
    private func showAlert(for event: CachedEvent, isExpired: Bool) {
        // 激活应用
        NSApp.activate(ignoringOtherApps: true)
        
        let alert = NSAlert()
        
        if isExpired {
            alert.messageText = "待办事项已过期"
            alert.alertStyle = .warning
        } else {
            alert.messageText = "待办事项即将到期"
            alert.alertStyle = .informational
        }
        
        let dateText = formatDate(event.startDate)
        let expiredText = isExpired ? "（已过期）" : ""
        alert.informativeText = "\(event.title ?? "未命名事项")\n\n\(dateText)\(expiredText)"
        
        alert.addButton(withTitle: "知道了")
        alert.addButton(withTitle: "标记完成")
        
        let response = alert.runModal()
        
        if response == .alertSecondButtonReturn {
            // 用户点击"标记完成"
            markAsCompleted(eventID: event.eventID)
        }
    }
    
    /// 显示合并的过期事项提醒弹窗
    private func showCombinedAlert(for events: [CachedEvent], isExpired: Bool) {
        // 激活应用
        NSApp.activate(ignoringOtherApps: true)
        
        let alert = NSAlert()
        alert.messageText = "\(events.count) 个待办事项\(isExpired ? "已过期" : "即将到期")"
        alert.alertStyle = isExpired ? .warning : .informational
        
        // 构建事项列表
        let itemsList = events.enumerated().map { index, event in
            let dateText = formatDate(event.startDate)
            return "\(index + 1). \(event.title ?? "未命名事项")\n   \(dateText)"
        }.joined(separator: "\n\n")
        
        alert.informativeText = itemsList
        
        alert.addButton(withTitle: "知道了")
        alert.addButton(withTitle: "全部标记完成")
        
        // 将对话框定位到活动屏幕的右上角
        var targetScreen: NSScreen?
        
        if let activeWindow = NSApp.keyWindow {
            targetScreen = activeWindow.screen
        }
        if targetScreen == nil {
            targetScreen = NSScreen.main ?? NSScreen.screens.first
        }
        
        if let screen = targetScreen {
            let screenFrame = screen.visibleFrame
            // 获取 alert 窗口的大小
            alert.window.layoutIfNeeded()
            let alertSize = alert.window.frame.size
            
            // 计算右上角位置
            let x = screenFrame.maxX - alertSize.width - 20
            let y = screenFrame.maxY - alertSize.height - 20
            
            // 创建新的 frame（使用 setFrame 而不是 setFrameOrigin）
            let newFrame = NSRect(
                x: x,
                y: y,
                width: alertSize.width,
                height: alertSize.height
            )
            
            // 设置窗口位置并立即显示
            alert.window.setFrame(newFrame, display: true)
            alert.window.makeKeyAndOrderFront(nil)
        }
        
        let response = alert.runModal()
        
        if response == .alertSecondButtonReturn {
            // 用户点击"全部标记完成"
            events.forEach { markAsCompleted(eventID: $0.eventID) }
        }
    }
    
    /// 标记事件为完成
    private func markAsCompleted(eventID: String) {
        guard let container = modelContainer else { return }
        
        let context = ModelContext(container)
        
        let descriptor = FetchDescriptor<CachedEvent>(
            predicate: #Predicate { $0.eventID == eventID }
        )
        
        do {
            if let event = try context.fetch(descriptor).first {
                // 使用 CalendarService 的双向同步方法（同时更新 EventKit 和 SwiftData）
                CalendarService.shared.toggleEventCompleted(
                    eventID: eventID,
                    isCompleted: true,
                    isReminder: event.calendarTitle == "提醒"
                )
                print("[ReminderAlertService] 已标记事件完成: \(eventID)")
            }
        } catch {
            print("[ReminderAlertService] 标记完成失败: \(error)")
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
    
    /// 限制 lastAlertedEventIDs 的大小，避免内存泄漏
    private func trimAlertedEventIDsIfNeeded() {
        if lastAlertedEventIDs.count > maxAlertedEventIDs {
            // 保留最近的 maxAlertedEventIDs 条记录
            let overflow = lastAlertedEventIDs.count - maxAlertedEventIDs
            // 由于 Set 无序，移除前半部分
            let toRemove = Array(lastAlertedEventIDs.prefix(overflow))
            for id in toRemove {
                lastAlertedEventIDs.remove(id)
            }
            print("[ReminderAlertService] 清理了 \(overflow) 个过期提醒记录")
        }
    }
    
    /// 清除已提醒记录（用于重置）
    func clearAlertHistory() {
        lastAlertedEventIDs.removeAll()
    }
}