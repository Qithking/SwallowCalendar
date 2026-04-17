//
//  CalendarHeaderView.swift
//  SwallowCalendar
//

import SwiftUI

struct CalendarHeaderView: View {
    @Binding var currentMonth: Date
    @Binding var selectedDate: Date

    @State private var showMonthPicker = false

    private let calendar = Calendar.current

    var body: some View {
        HStack {
            // 上一月
            Button {
                withAnimation {
                    currentMonth = calendar.date(byAdding: .month, value: -1, to: currentMonth) ?? currentMonth
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)

            Spacer()

            // 当前年月（点击弹出年月选择器）
            Button {
                showMonthPicker = true
            } label: {
                Text(monthTitle)
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showMonthPicker, arrowEdge: .bottom) {
                MonthYearPickerView(currentMonth: $currentMonth, selectedDate: $selectedDate)
            }

            Spacer()

            // 下一月
            Button {
                withAnimation {
                    currentMonth = calendar.date(byAdding: .month, value: 1, to: currentMonth) ?? currentMonth
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月"
        return formatter.string(from: currentMonth)
    }
}

// MARK: - Month Year Picker

struct MonthYearPickerView: View {
    @Binding var currentMonth: Date
    @Binding var selectedDate: Date
    @Environment(\.dismiss) private var dismiss

    private let calendar = Calendar.current

    @State private var selectedYear: Int
    @State private var selectedMonth: Int

    init(currentMonth: Binding<Date>, selectedDate: Binding<Date>) {
        self._currentMonth = currentMonth
        self._selectedDate = selectedDate
        let now = currentMonth.wrappedValue
        let cal = Calendar.current
        _selectedYear = State(initialValue: cal.component(.year, from: now))
        _selectedMonth = State(initialValue: cal.component(.month, from: now))
    }

    private let months = ["1月", "2月", "3月", "4月", "5月", "6月",
                          "7月", "8月", "9月", "10月", "11月", "12月"]

    var body: some View {
        VStack(spacing: 0) {
            // 年份选择
            HStack {
                Button {
                    withAnimation { selectedYear -= 1 }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)

                Spacer()

                Text("\(selectedYear)年")
                    .font(.system(size: 13, weight: .semibold))

                Spacer()

                Button {
                    withAnimation { selectedYear += 1 }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // 月份网格
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                ForEach(1...12, id: \.self) { month in
                    Button {
                        selectMonth(month)
                    } label: {
                        Text(months[month - 1])
                            .font(.system(size: 12))
                            .foregroundColor(month == selectedMonth ? .white : .primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(
                                month == selectedMonth
                                    ? RoundedRectangle(cornerRadius: 4).fill(Color.accentColor)
                                    : RoundedRectangle(cornerRadius: 4).fill(Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)

            Divider()

            // 今天按钮
            Button {
                selectedYear = calendar.component(.year, from: Date())
                selectedMonth = calendar.component(.month, from: Date())
                selectMonth(selectedMonth)
            } label: {
                Text("今天")
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
        }
        .frame(width: 220)
    }

    private func selectMonth(_ month: Int) {
        var components = DateComponents()
        components.year = selectedYear
        components.month = month
        components.day = 1

        if let date = calendar.date(from: components) {
            withAnimation {
                currentMonth = date
                selectedDate = date
            }
        }
        dismiss()
    }
}
