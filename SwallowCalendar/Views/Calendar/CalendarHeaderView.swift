//
//  CalendarHeaderView.swift
//  SwallowCalendar
//

import SwiftUI

struct CalendarHeaderView: View {
    @Environment(AppSettings.self) private var appSettings
    @Binding var currentMonth: Date
    @Binding var selectedDate: Date

    @State private var showMonthPicker = false
    @State private var accentColor: Color = Color(hex: AppSettings.shared.accentColorHex)

    private let calendar = Calendar.current

    var body: some View {
        HStack {
            // 左侧：当前年月（点击弹出年月选择器）
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

            // 右侧：月份导航
            HStack(spacing: 12) {
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

                // 今天按钮
                Button {
                    withAnimation {
                        currentMonth = Date()
                        selectedDate = Date()
                    }
                } label: {
                    Text("今天")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(accentColor)
                }
                .buttonStyle(.plain)

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
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .onChange(of: appSettings.accentColorHex) { _, newColor in
            accentColor = Color(hex: newColor)
        }
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
    @Environment(AppSettings.self) private var appSettings
    @Binding var currentMonth: Date
    @Binding var selectedDate: Date
    @Environment(\.dismiss) private var dismiss

    private let calendar = Calendar.current

    @State private var selectedYear: Int
    @State private var selectedMonth: Int
    @State private var yearText: String = ""
    @State private var accentColor: Color = Color(hex: AppSettings.shared.accentColorHex)

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
            // 年份选择（支持自定义输入）
            HStack {
                Button {
                    withAnimation { selectedYear -= 1; updateYearText() }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)

                Spacer()

                TextField("年份", text: $yearText)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 60)
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        commitYearEdit()
                    }
                    .onChange(of: yearText) { _, newValue in
                        // 仅允许数字
                        yearText = newValue.filter { $0.isNumber }
                    }

                Text("年")
                    .font(.system(size: 13, weight: .semibold))

                Spacer()

                Button {
                    withAnimation { selectedYear += 1; updateYearText() }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .onAppear {
                updateYearText()
            }

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
                                    ? RoundedRectangle(cornerRadius: 4).fill(accentColor)
                                    : RoundedRectangle(cornerRadius: 4).fill(Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
        .frame(width: 220)
        .onChange(of: appSettings.accentColorHex) { _, newColor in
            accentColor = Color(hex: newColor)
        }
    }

    private func selectMonth(_ month: Int) {
        commitYearEdit()
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

    private func updateYearText() {
        yearText = "\(selectedYear)"
    }

    private func commitYearEdit() {
        if let year = Int(yearText), year >= 1900, year <= 2100 {
            selectedYear = year
        } else {
            // 无效输入，回退到当前选中的年份
            yearText = "\(selectedYear)"
        }
    }
}
