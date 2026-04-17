//
//  ContentView.swift
//  SwallowCalendar
//
//  Created by thking on 2026/4/17.
//

import SwiftUI
import SwiftData
import EventKit

struct ContentView: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.modelContext) private var modelContext
    @Query private var customSources: [CustomCalendarSource]
    @Query private var calendarPreferences: [CalendarPreference]

    @State private var selectedDate = Date()
    @State private var calendarService = CalendarService.shared
    @State private var icsService = ICSService.shared

    var body: some View {
        VStack(spacing: 0) {
            // 日历区域
            CalendarGridView(
                selectedDate: $selectedDate,
                calendarService: calendarService,
                icsService: icsService,
                customSources: customSources,
                calendarPreferences: calendarPreferences
            )

            Divider()

            // 事项区域（占满剩余空间）
            EventPanelView(
                selectedDate: selectedDate,
                calendarService: calendarService,
                calendarPreferences: calendarPreferences
            )
            .frame(maxHeight: .infinity)

            Divider()

            // 工具栏
            toolbar
        }
        .preferredColorScheme(appSettings.colorScheme)
        .task {
            await initializeServices()
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack {
            // 设置按钮
            Button {
                SettingsWindowManager.shared.openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .help("设置")

            Spacer()

            // 今日按钮
            Button {
                withAnimation {
                    selectedDate = Date()
                }
            } label: {
                Text("今天")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help("回到今天")

            Spacer()

            // 退出按钮
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .help("退出应用")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.clear)
    }

    // MARK: - Services Init

    private func initializeServices() async {
        // 请求日历权限
        if calendarService.authorizationStatus == .notDetermined {
            _ = await calendarService.requestAccess()
        }

        await calendarService.loadCalendars()

        // 初始化默认自定义日历（中国节假日）
        if customSources.isEmpty {
            let defaultSource = CustomCalendarSource(
                name: "中国节假日",
                icsURL: "https://yangh9.github.io/ChinaCalendar/cal_holiday.ics",
                isEnabled: true
            )
            modelContext.insert(defaultSource)
        }

        // 预加载节假日数据
        await icsService.preloadHolidays(sources: customSources)
    }
}
