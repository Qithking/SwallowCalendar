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
    
    /// 显示合并的过期事项提醒弹窗（自定义 SwiftUI 窗口，替代系统 NSAlert）
    private func showCombinedAlert(for events: [CachedEvent], isExpired: Bool) {
        ReminderAlertWindowController.shared.show(events: events, isExpired: isExpired) {
            Task { @MainActor in
                for event in events {
                    await self.markAsCompleted(eventID: event.eventID)
                }
            }
        }
    }

    /// 标记事件为完成
    private func markAsCompleted(eventID: String) async {
        // 使用 EventCacheService 的统一上下文，确保与 @Query 同步
        guard let context = EventCacheService.shared.context else { return }

        let descriptor = FetchDescriptor<CachedEvent>(
            predicate: #Predicate { $0.eventID == eventID }
        )

        do {
            if let event = try context.fetch(descriptor).first {
                // 使用 CalendarService 的双向同步方法（同时更新 EventKit 和 SwiftData）
                await CalendarService.shared.toggleEventCompleted(
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