//
//  DataExportSettingsView.swift
//  SwallowCalendar
//

import SwiftUI
import EventKit
import SwiftData

struct DataExportSettingsView: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.modelContext) private var modelContext
    @State private var isExporting = false
    @State private var showExportSuccess = false
    @State private var showExportError = false
    @State private var errorMessage = ""
    @State private var showClearConfirm = false
    @State private var isClearing = false
    @State private var clearStatus: ClearStatus?  // 清除操作的状态反馈
    
    var body: some View {
        Form {
            Section("数据导出") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("将日历事件导出为标准 ICS 格式文件，可用于备份或导入到其他日历应用。")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    
                    Button {
                        exportToICS()
                    } label: {
                        HStack {
                            if isExporting {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Image(systemName: "square.and.arrow.up")
                            Text(isExporting ? "导出中..." : "导出所有日历事件")
                        }
                    }
                    .disabled(isExporting)
                }
                .padding(.vertical, 4)
            }
            
            Section("数据管理") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("清除本地存储的事件数据，不会影响系统日历中的原始数据。")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        HStack {
                            // 状态反馈图标
                            if let status = clearStatus {
                                status.icon
                                    .foregroundStyle(status.color)
                                    .transition(.scale)
                            }
                            
                            if isClearing {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "trash")
                            }
                            Text(isClearing ? "清除中..." : "清除本地事件")
                        }
                    }
                    .disabled(isClearing)
                    .animation(.easeInOut(duration: 0.2), value: clearStatus)
                }
                .padding(.vertical, 4)
            }
            
            Section("统计") {
                HStack {
                    Text("本地事件数")
                    Spacer()
                    Text("\(cachedEventCount)")
                        .foregroundColor(.secondary)
                }
                
                if let lastSync = EventCacheService.shared.lastSyncTime {
                    HStack {
                        Text("上次同步")
                        Spacer()
                        Text(lastSync, formatter: dateFormatter)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .tint(Color(hex: appSettings.accentColorHex))
        .alert("导出成功", isPresented: $showExportSuccess) {
            Button("确定") {}
        } message: {
            Text("日历事件已成功导出到桌面。")
        }
        .alert("导出失败", isPresented: $showExportError) {
            Button("确定") {}
        } message: {
            Text(errorMessage)
        }
        .alert("确认清除", isPresented: $showClearConfirm) {
            Button("取消", role: .cancel) {}
            Button("确认清除", role: .destructive) {
                clearEventCache()
            }
        } message: {
            Text("此操作将清除本地存储的所有事件数据，但不会影响系统日历中的原始数据。")
        }
    }
    
    private var cachedEventCount: Int {
        let descriptor = FetchDescriptor<CachedEvent>()
        return (try? modelContext.fetch(descriptor).count) ?? 0
    }

    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }
    
    private func exportToICS() {
        isExporting = true
        
        Task {
            do {
                // 获取所有事件
                let calendarService = CalendarService.shared
                let now = Date()
                let endDate = Calendar.current.date(byAdding: .year, value: 2, to: now)!
                
                // 获取所有启用的日历
                let descriptor = FetchDescriptor<CalendarPreference>()
                let preferences = (try? modelContext.fetch(descriptor)) ?? []
                let enabledCals = calendarService.enabledCalendars(preferences: preferences)
                
                let events = calendarService.fetchEvents(from: now, to: endDate, calendars: enabledCals)
                
                // 生成 ICS 内容
                let icsContent = generateICS(events: events)
                
                // 保存到桌面
                let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
                let fileName = "SwallowCalendar_Export_\(formatDate(now)).ics"
                let fileURL = desktopURL.appendingPathComponent(fileName)
                
                try icsContent.write(to: fileURL, atomically: true, encoding: .utf8)
                
                await MainActor.run {
                    isExporting = false
                    showExportSuccess = true
                }
            } catch {
                await MainActor.run {
                    isExporting = false
                    errorMessage = error.localizedDescription
                    showExportError = true
                }
            }
        }
    }
    
    private func clearEventCache() {
        isClearing = true
        
        Task {
            do {
                // 模拟异步操作（实际 clearCache 是同步的，但为了 UI 反馈使用 Task）
                try await Task.sleep(nanoseconds: 100_000_000)  // 100ms 延迟让用户看到进度
                
                EventCacheService.shared.clearCache()
                ICSService.shared.clearCache()

                // 通知其他视图缓存已清除，需要刷新
                NotificationCenter.default.post(name: Notification.Name("CalendarCacheCleared"), object: nil)
                
                await MainActor.run {
                    isClearing = false
                    clearStatus = .success
                    
                    // 5 秒后自动清除状态
                    Task {
                        try await Task.sleep(nanoseconds: 5_000_000_000)  // 5 秒
                        await MainActor.run {
                            clearStatus = nil
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    isClearing = false
                    clearStatus = .failure
                    
                    // 5 秒后自动清除状态
                    Task {
                        try await Task.sleep(nanoseconds: 5_000_000_000)  // 5 秒
                        await MainActor.run {
                            clearStatus = nil
                        }
                    }
                }
            }
        }
    }
    
    private func generateICS(events: [CalendarEvent]) -> String {
        var lines: [String] = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//SwallowCalendar//EN",
            "CALSCALE:GREGORIAN",
            "METHOD:PUBLISH"
        ]
        
        for event in events {
            lines.append("BEGIN:VEVENT")
            lines.append("UID:\(event.id)")
            lines.append("DTSTAMP:\(formatICSDate(Date()))")
            
            if let start = event.startDate {
                if event.isAllDay {
                    lines.append("DTSTART;VALUE=DATE:\(formatICSDateOnly(start))")
                    if let end = event.endDate {
                        lines.append("DTEND;VALUE=DATE:\(formatICSDateOnly(end))")
                    } else {
                        lines.append("DTEND;VALUE=DATE:\(formatICSDateOnly(start))")
                    }
                } else {
                    lines.append("DTSTART:\(formatICSDate(start))")
                    if let end = event.endDate {
                        lines.append("DTEND:\(formatICSDate(end))")
                    } else {
                        lines.append("DTEND:\(formatICSDate(start))")
                    }
                }
            }
            
            lines.append("SUMMARY:\(escapeICSText(event.title))")
            lines.append("END:VEVENT")
        }
        
        lines.append("END:VCALENDAR")
        return lines.joined(separator: "\r\n")
    }
    
    private func formatICSDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
    
    private func formatICSDateOnly(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }
    
    private func escapeICSText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: date)
    }
}

// MARK: - Clear Status

enum ClearStatus {
    case success
    case failure
    
    var icon: Image {
        switch self {
        case .success:
            return Image(systemName: "checkmark.circle.fill")
        case .failure:
            return Image(systemName: "xmark.circle.fill")
        }
    }
    
    var color: Color {
        switch self {
        case .success:
            return .green
        case .failure:
            return .red
        }
    }
}
