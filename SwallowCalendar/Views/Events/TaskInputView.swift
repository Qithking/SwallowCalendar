//
//  TaskInputView.swift
//  SwallowCalendar
//

import SwiftUI

struct TaskInputView: View {
    let calendarService: CalendarService
    let calendarPreferences: [CalendarPreference]

    @State private var inputText = ""
    @State private var isProcessing = false
    @State private var parsePreview: ParsedTask?

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: "plus.circle.fill")
                    .foregroundColor(.accentColor)
                    .font(.system(size: 14))

                TextField("输入待办，如：明天下午3点开会", text: $inputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit {
                        addTask()
                    }
                    .onChange(of: inputText) { _, newValue in
                        updatePreview(newValue)
                    }

                if !inputText.isEmpty {
                    Button {
                        addTask()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(isProcessing)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
            )

            // 解析预览
            if let preview = parsePreview, !inputText.isEmpty {
                previewTags(preview)
            }
        }
    }

    // MARK: - Preview Tags

    @ViewBuilder
    private func previewTags(_ preview: ParsedTask) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                // 标题
                Text(preview.title)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Text("·")
                    .foregroundColor(.secondary)

                // 日期时间
                Text(formatDate(preview.date))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)

                // 农历标记
                if preview.isLunar {
                    tagView("农历", color: .orange)
                }

                // 颜色标签
                if let color = preview.color {
                    tagView(color.displayName, color: Color(hex: color.rawValue))
                }

                // 优先级标签
                if let priority = preview.priority {
                    tagView("优先:\(priority.displayName)", color: priorityColor(priority))
                }

                // 周期标签
                if let recurrence = preview.recurrence, recurrence != .none {
                    tagView(recurrence.rawValue, color: .blue)
                }

                // 提醒时间
                if let minutes = preview.reminderMinutes {
                    let text = minutes >= 1440 ? "提前\(minutes / 1440)天" :
                               minutes >= 60 ? "提前\(minutes / 60)小时" : "提前\(minutes)分钟"
                    tagView(text, color: .purple)
                }
            }
            .padding(.leading, 24)
        }
    }

    private func tagView(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9))
            .foregroundColor(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(color.opacity(0.15))
            )
    }

    private func priorityColor(_ priority: EventPriority) -> Color {
        switch priority {
        case .high: return .red
        case .medium: return .orange
        case .low: return .gray
        case .none: return .secondary
        }
    }

    // MARK: - Actions

    private func updatePreview(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            parsePreview = nil
            return
        }
        parsePreview = NLPTaskParser.parse(text)
    }

    private func addTask() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }

        let parsed = NLPTaskParser.parse(text)
        isProcessing = true

        let isAllDay = Calendar.current.component(.hour, from: parsed.date) == 0
            && Calendar.current.component(.minute, from: parsed.date) == 0

        do {
            try calendarService.createEvent(
                title: parsed.title,
                startDate: parsed.date,
                endDate: isAllDay ? nil : parsed.date.addingTimeInterval(3600),
                isAllDay: isAllDay,
                calendar: nil,
                priority: parsed.priority,
                recurrence: parsed.recurrence,
                reminderMinutes: parsed.reminderMinutes
            )
            inputText = ""
            parsePreview = nil
        } catch {
            print("Failed to create event: \(error)")
        }

        isProcessing = false
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
