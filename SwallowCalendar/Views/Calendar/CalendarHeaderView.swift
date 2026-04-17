//
//  CalendarHeaderView.swift
//  SwallowCalendar
//

import SwiftUI

struct CalendarHeaderView: View {
    @Binding var currentMonth: Date
    @Binding var selectedDate: Date

    private let calendar = Calendar.current

    private var currentYear: Int {
        calendar.component(.year, from: currentMonth)
    }

    private var currentMonthValue: Int {
        calendar.component(.month, from: currentMonth)
    }

    private let months = ["1月", "2月", "3月", "4月", "5月", "6月",
                          "7月", "8月", "9月", "10月", "11月", "12月"]

    var body: some View {
        HStack(spacing: 8) {
            // 年份下拉
            Menu {
                ForEach(yearRange, id: \.self) { year in
                    Button("\(year)") {
                        selectYear(year)
                    }
                }
            } label: {
                HStack(spacing: 2) {
                    Text("\(currentYear)")
                        .font(.system(size: 14, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .foregroundColor(.primary)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 56)

            // 月份下拉
            Menu {
                ForEach(1...12, id: \.self) { month in
                    Button(months[month - 1]) {
                        selectMonth(month)
                    }
                }
            } label: {
                HStack(spacing: 2) {
                    Text(months[currentMonthValue - 1])
                        .font(.system(size: 14, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .foregroundColor(.primary)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 48)

            Spacer()

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
                    let today = Date()
                    currentMonth = today
                    selectedDate = today
                }
            } label: {
                Text("今天")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.accentColor.opacity(0.15))
                    )
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
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
    }

    private var yearRange: [Int] {
        let currentYear = calendar.component(.year, from: Date())
        return Array((currentYear - 20)...(currentYear + 20))
    }

    private func selectYear(_ year: Int) {
        var components = calendar.dateComponents([.year, .month], from: currentMonth)
        components.year = year
        if let date = calendar.date(from: components) {
            withAnimation {
                currentMonth = date
            }
        }
    }

    private func selectMonth(_ month: Int) {
        var components = calendar.dateComponents([.year, .month], from: currentMonth)
        components.month = month
        components.day = 1
        if let date = calendar.date(from: components) {
            withAnimation {
                currentMonth = date
                selectedDate = date
            }
        }
    }
}
