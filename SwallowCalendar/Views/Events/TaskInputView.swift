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
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text(preview.title)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Text("·")
                        .foregroundColor(.secondary)
                    Text(formatDate(preview.date))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(.leading, 24)
            }
        }
    }

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
                calendar: nil
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
