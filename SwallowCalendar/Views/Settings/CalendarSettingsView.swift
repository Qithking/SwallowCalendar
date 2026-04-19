//
//  CalendarSettingsView.swift
//  SwallowCalendar
//

import SwiftUI
import EventKit
import SwiftData

struct CalendarSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppSettings.self) private var appSettings
    @Query private var calendarPreferences: [CalendarPreference]
    @Query private var customSources: [CustomCalendarSource]
    @State private var calendarService = CalendarService.shared

    @State private var newSourceName = ""
    @State private var newSourceURL = ""

    var body: some View {
        @Bindable var settings = appSettings

        Form {
            // 显示选项
            Section("显示选项") {
                Toggle("显示农历", isOn: $settings.showLunarCalendar)
            }

            // 日历分类
            // 日历分类
            Section("系统日历分类") {
                ColorPicker("分类颜色", selection: Binding(
                    get: { Color(hex: settings.systemCalendarColorHex) },
                    set: { settings.systemCalendarColorHex = $0.toHex() ?? settings.systemCalendarColorHex }
                ))
                    .font(.system(size: 12))

                Divider()

                if calendarService.calendars.isEmpty {
                    Text("暂无可用的日历")
                        .foregroundColor(.secondary)
                        .font(.system(size: 11))
                } else {
                    ForEach(calendarService.calendars, id: \.calendarIdentifier) { cal in
                        let pref = calendarPreferences.first(where: { $0.calendarID == cal.calendarIdentifier })
                        let isOn = Binding<Bool>(
                            get: { pref?.isEnabled ?? true },
                            set: { newValue in
                                updateCalendarPreference(id: cal.calendarIdentifier, isEnabled: newValue)
                            }
                        )

                        Toggle(isOn: isOn) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color(cgColor: cal.cgColor))
                                    .frame(width: 8, height: 8)
                                Text(cal.title)
                                    .font(.system(size: 12))
                            }
                        }
                    }
                }
            }

            // 自定义日历
            Section("自定义日历 (ICS)") {
                ColorPicker("分类颜色", selection: Binding(
                    get: { Color(hex: settings.subscriptionCalendarColorHex) },
                    set: { settings.subscriptionCalendarColorHex = $0.toHex() ?? settings.subscriptionCalendarColorHex }
                ))
                    .font(.system(size: 12))

                Divider()

                ForEach(customSources, id: \.id) { source in
                    HStack(spacing: 6) {
                        Toggle("", isOn: Binding(
                            get: { source.isEnabled },
                            set: { newValue in
                                source.isEnabled = newValue
                            }
                        ))
                        .labelsHidden()

                        Text(source.name)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .frame(minWidth: 60, maxWidth: 80)

                        Text(source.icsURL)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()

                        Button {
                            modelContext.delete(source)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // 添加新源
                HStack(spacing: 8) {
                    TextField("名称", text: $newSourceName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    TextField("ICS URL", text: $newSourceURL)
                        .textFieldStyle(.roundedBorder)
                    Button("添加") {
                        addCustomSource()
                    }
                    .disabled(newSourceName.isEmpty || newSourceURL.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .tint(Color(hex: appSettings.accentColorHex))
        .task {
            calendarService.loadCalendars()
        }
    }

    private func updateCalendarPreference(id: String, isEnabled: Bool) {
        if let existing = calendarPreferences.first(where: { $0.calendarID == id }) {
            existing.isEnabled = isEnabled
        } else {
            let pref = CalendarPreference(calendarID: id, isEnabled: isEnabled)
            modelContext.insert(pref)
        }
    }

    private func addCustomSource() {
        let source = CustomCalendarSource(
            name: newSourceName,
            icsURL: newSourceURL,
            isEnabled: true
        )
        modelContext.insert(source)
        newSourceName = ""
        newSourceURL = ""
    }
}
