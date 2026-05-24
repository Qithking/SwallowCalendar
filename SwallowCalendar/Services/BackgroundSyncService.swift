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

    func start() {
        Task {
            await syncOnce()
            startTimer()
        }
    }

    func syncOnce() async {
        guard !isSyncing else { return }
        guard let container = modelContainer else { return }
        guard CalendarService.shared.authorizationStatus == .fullAccess else { return }

        isSyncing = true
        defer { isSyncing = false }

        let context = ModelContext(container)

        let preferences = fetchPreferences(context: context)
        let customSources = fetchCustomSources(context: context)

        let enabledCals = CalendarService.shared.enabledCalendars(preferences: preferences)

        if !enabledCals.isEmpty {
            await CalendarService.shared.cacheService.syncEvents(from: CalendarService.shared, calendars: enabledCals)
        } else {
            CalendarService.shared.cacheService.clearSystemCalendarCache()
        }

        if AppSettings.shared.syncSystemReminders && CalendarService.shared.reminderAuthorizationStatus == .fullAccess {
            await CalendarService.shared.cacheService.syncReminders(from: CalendarService.shared)
        } else {
            CalendarService.shared.cacheService.clearRemindersCache()
        }

        let enabledSources = customSources.filter { $0.isEnabled }
        if !enabledSources.isEmpty {
            await CalendarService.shared.cacheService.syncSubscriptionEvents(sources: enabledSources)
        }

        await ReminderAlertService.shared.checkExpiredEvents()

        NotificationCenter.default.post(name: Notification.Name("CalendarCacheCleared"), object: nil)
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
