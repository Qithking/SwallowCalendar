//
//  BackgroundSyncService.swift
//  SwallowCalendar
//
//  后台静默定时同步服务
//

import Foundation
import SwiftData
import EventKit

@MainActor
final class BackgroundSyncService {
    static let shared = BackgroundSyncService()

    private var modelContainer: ModelContainer?
    private var syncTimer: Timer?
    private var isSyncing = false

    private let syncIntervalSeconds: TimeInterval = 60 * 60

    private init() {}

    func configure(with container: ModelContainer) {
        self.modelContainer = container
    }

    /// 设置主上下文（由 ContentView 注入，确保与 @Query 共享同一上下文）
    func setMainContext(_ context: ModelContext) {
        EventCacheService.shared.setMainContext(context)
    }

    func start() async {
        await syncOnce()
        startTimer()
    }

    func syncOnce() async {
        guard !isSyncing else { return }
        guard let container = modelContainer else { return }
        guard CalendarService.shared.authorizationStatus == .fullAccess else { return }

        isSyncing = true
        defer { isSyncing = false }

        // 使用 EventCacheService 的统一上下文（优先为环境上下文，与 @Query 共享）
        guard let context = EventCacheService.shared.context else { return }

        let preferences = fetchPreferences(context: context)
        let customSources = fetchCustomSources(context: context)

        let enabledCals = CalendarService.shared.enabledCalendars(preferences: preferences)

        if !enabledCals.isEmpty {
            await CalendarService.shared.cacheService.syncEvents(from: CalendarService.shared, calendars: enabledCals)
        } else {
            await CalendarService.shared.cacheService.clearSystemCalendarCache()
        }

        if AppSettings.shared.syncSystemReminders && CalendarService.shared.reminderAuthorizationStatus == .fullAccess {
            await CalendarService.shared.cacheService.syncReminders(from: CalendarService.shared)
        } else {
            await CalendarService.shared.cacheService.clearRemindersCache()
        }

        let enabledSources = customSources.filter { $0.isEnabled }
        if !enabledSources.isEmpty {
            await CalendarService.shared.cacheService.syncSubscriptionEvents(sources: enabledSources)
        }
    }

    private func startTimer() {
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: syncIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.syncOnce()
            }
        }
    }

    func stop() {
        syncTimer?.invalidate()
        syncTimer = nil
    }

    private func fetchPreferences(context: ModelContext) -> [CalendarPreference] {
        let descriptor = FetchDescriptor<CalendarPreference>()
        return (try? context.fetch(descriptor)) ?? []
    }

    private func fetchCustomSources(context: ModelContext) -> [CustomCalendarSource] {
        let descriptor = FetchDescriptor<CustomCalendarSource>()
        return (try? context.fetch(descriptor)) ?? []
    }
}
