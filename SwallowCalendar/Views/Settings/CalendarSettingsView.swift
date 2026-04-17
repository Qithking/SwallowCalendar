//
//  CalendarSettingsView.swift
//  SwallowCalendar
//

import SwiftUI
import EventKit
import SwiftData

struct CalendarSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var calendarPreferences: [CalendarPreference]
    @Query private var customSources: [CustomCalendarSource]
    @State private var calendarService = CalendarService.shared

    @State private var newSourceName = ""
    @State private var newSourceURL = ""

    var body: some View {
        Form {
            // 日历分类
            Section("系统日历分类") {
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
                                    .fill(Color(cgColor: cal.cgColor) ?? .accentColor)
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
                ForEach(customSources, id: \.id) { source in
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(
                            get: { source.isEnabled },
                            set: { newValue in
                                source.isEnabled = newValue
                            }
                        ))
                        .labelsHidden()

                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.name)
                                .font(.system(size: 12))
                            Text(source.icsURL)
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }

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
                HStack {
                    TextField("名称", text: $newSourceName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
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
        .task {
            await calendarService.loadCalendars()
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
