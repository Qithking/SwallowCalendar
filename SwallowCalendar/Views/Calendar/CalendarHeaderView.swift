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
    // 直接读 appSettings 主题色，无需 @State 复制与 onChange 同步
    private var accentColor: Color { Color(hex: appSettings.accentColorHex) }

    private let calendar = Calendar.current

    var body: some View {
        HStack {
            // 左侧：当前年月（点击弹出年月选择器）
            NavToolbarButton(help: "选择年月") {
                showMonthPicker = true
            } label: {
                Text(monthTitle)
                    .font(.system(size: 14, weight: .semibold))
            }
            .focusEffectDisabled()
            .popover(isPresented: $showMonthPicker, arrowEdge: .bottom) {
                MonthYearPickerView(currentMonth: $currentMonth, selectedDate: $selectedDate)
            }

            Spacer()

            // 右侧：月份导航（命中区域扩大 + hover 反馈，间距由按钮内 padding 提供）
            HStack(spacing: 0) {
                // 上一月
                NavToolbarButton(help: "上一月") {
                    withAnimation {
                        currentMonth = calendar.date(byAdding: .month, value: -1, to: currentMonth) ?? currentMonth
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                }

                // 今天按钮
                NavToolbarButton(help: "回到今天") {
                    withAnimation {
                        currentMonth = Date()
                        selectedDate = Date()
                    }
                } label: {
                    Text("今天")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(accentColor)
                }

                // 下一月
                NavToolbarButton(help: "下一月") {
                    withAnimation {
                        currentMonth = calendar.date(byAdding: .month, value: 1, to: currentMonth) ?? currentMonth
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
    }

    // monthTitle 用静态缓存 DateFormatter——每次求值新建开销大（仅主线程 body 使用）
    private static let monthTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月"
        return formatter
    }()

    private var monthTitle: String {
        Self.monthTitleFormatter.string(from: currentMonth)
    }
}

// MARK: - Nav Toolbar Button

/// 月导航工具栏按钮：命中区域扩大（padding + contentShape 透明区可点）、
/// hover 淡灰圆角背景 + 手型光标（对齐系统日历工具栏风格）
private struct NavToolbarButton<Label: View>: View {
    let help: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            label()
                // padding 扩大命中区域；contentShape 让含透明区的整个矩形可点
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            // set 幂等覆盖，不用 push/pop——项目已实证 onHover(false) 可能不触发
            //（EventItemRow 同款坑），栈式操作会累积错乱光标栈
            (hovering ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
        .help(help)
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
    // 直接读 appSettings 主题色，无需 @State 复制与 onChange 同步
    private var accentColor: Color { Color(hex: appSettings.accentColorHex) }

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
