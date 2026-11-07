//
//  RecurrencePickerView.swift
//  SwallowCalendar
//
//  新建/编辑共享的循环选择器：严格对齐「提醒事项」12 项预设 + 自定义维度
//

import SwiftUI

struct RecurrencePickerView: View {
    @Binding var preset: RecurrencePreset
    @Binding var spec: RecurrenceSpec?
    let anchor: Date
    let isLunar: Bool
    /// 用户改动后回调（父视图同步旧档位字段与「手动修改」标记）
    var onChange: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: FormMetrics.rowSpacing) {
            Picker("", selection: $preset) {
                ForEach(RecurrencePreset.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .labelsHidden()
            // 控件右对齐基准：下拉按固有宽度贴右，与开关/日期共用同一条基准线
            .formControlSizing()
            .frame(maxWidth: .infinity, alignment: .trailing)
            .onChange(of: preset) { _, newValue in
                guard newValue != .custom else {
                    // 自定义进入时保证有可编辑底稿（保留现有维度）
                    if spec == nil { spec = RecurrenceSpec(frequency: .daily, interval: 1) }
                    onChange()
                    return
                }
                spec = RecurrenceSpec.spec(for: newValue, anchor: anchor, current: spec)
                onChange()
            }

            if preset == .custom, spec != nil {
                customEditor
            } else if preset == .custom {
                Button("配置自定义规则") {
                    spec = RecurrenceSpec(frequency: .daily, interval: 1)
                    onChange()
                }
                .buttonStyle(.link)
            }

            if spec != nil, spec?.frequency == .hourly || isLunar {
                FormHint(isLunar
                         ? "农历重复仅应用内生效；系统「提醒事项」中显示为「永不」"
                         : "每小时仅应用内生效；系统「提醒事项」中显示为「永不」")
            }
        }
        // 展开态与收起态都占满控件列，避免自定义面板撑破整行宽度
        .frame(maxWidth: .infinity, alignment: .leading)
        // 日期变化后固定预设需重新以新日期为锚点推导（每月几号/每年几月）
        .onChange(of: anchor) { _, newAnchor in
            guard preset != .custom else { return }
            spec = RecurrenceSpec.spec(for: preset, anchor: newAnchor, current: spec)
        }
    }

    // MARK: - 自定义面板

    @ViewBuilder
    private var customEditor: some View {
        let binding = Binding<RecurrenceSpec>(
            get: { spec ?? RecurrenceSpec(frequency: .daily, interval: 1) },
            set: { spec = $0; onChange() }
        )
        VStack(alignment: .leading, spacing: FormMetrics.rowSpacing) {
            innerRow("频率") {
                Picker("", selection: binding.frequency) {
                    ForEach(RecurrenceFrequency.allCases, id: \.self) { frequency in
                        Text("每\(frequency.displayName)").tag(frequency)
                    }
                }
                .labelsHidden()
                .frame(width: FormMetrics.compactControlWidth)
            }

            innerRow("间隔") {
                Stepper("每 \(binding.wrappedValue.interval) \(binding.wrappedValue.frequency.displayName)",
                        value: binding.interval, in: 1...99)
                    .controlSize(.small)
            }

            if binding.wrappedValue.frequency == .weekly {
                weekdayToggles(binding)
            }

            if binding.wrappedValue.frequency == .yearly {
                innerRow("月份") {
                    Picker("", selection: Binding(
                        get: { binding.wrappedValue.months.first ?? Calendar.current.component(.month, from: anchor) },
                        set: { binding.wrappedValue.months = [$0] }
                    )) {
                        ForEach(1...12, id: \.self) { Text("\($0)月").tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 78)
                }
            }

            if binding.wrappedValue.frequency == .monthly || binding.wrappedValue.frequency == .yearly {
                monthDayOrNthEditor(binding)
            }

            endEditor(binding)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }

    /// 自定义面板内的行：统一 44pt 标签列，右侧控件不越出面板宽度
    private func innerRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: FormMetrics.labelControlGap) {
            FormLabel(label, width: FormMetrics.innerLabelWidth)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func weekdayToggles(_ binding: Binding<RecurrenceSpec>) -> some View {
        let names = ["日", "一", "二", "三", "四", "五", "六"]
        return HStack(spacing: 3) {
            ForEach(1...7, id: \.self) { weekday in
                let selected = binding.wrappedValue.weekdays.contains(weekday)
                Button(names[weekday - 1]) {
                    var days = binding.wrappedValue.weekdays
                    if selected { days.removeAll { $0 == weekday } } else { days.append(weekday) }
                    binding.wrappedValue.weekdays = days.sorted()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(selected ? Color.accentColor : Color.gray)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func monthDayOrNthEditor(_ binding: Binding<RecurrenceSpec>) -> some View {
        let usesNth = binding.wrappedValue.nthWeekday != nil
        let calendar = Calendar.current
        return VStack(alignment: .leading, spacing: FormMetrics.rowSpacing) {
            Picker("", selection: Binding(
                get: { usesNth ? 1 : 0 },
                set: { mode in
                    if mode == 1 {
                        binding.wrappedValue.nthWeekday = NthWeekday(
                            nth: 1,
                            weekday: calendar.component(.weekday, from: anchor)
                        )
                        binding.wrappedValue.monthDay = nil
                    } else {
                        binding.wrappedValue.nthWeekday = nil
                        binding.wrappedValue.monthDay = calendar.component(.day, from: anchor)
                    }
                }
            )) {
                Text("按日期").tag(0)
                Text("按第几个周几").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if let nth = binding.wrappedValue.nthWeekday {
                HStack(spacing: 6) {
                    Picker("", selection: Binding(
                        get: { nth.nth },
                        set: { binding.wrappedValue.nthWeekday?.nth = $0 }
                    )) {
                        Text("第一个").tag(1)
                        Text("第二个").tag(2)
                        Text("第三个").tag(3)
                        Text("第四个").tag(4)
                        Text("最后一个").tag(-1)
                    }
                    .labelsHidden()
                    // 自定义面板内可用宽度有限，用 maxWidth 让控件可收缩，避免撑出卡片破坏右基准
                    .frame(maxWidth: 84)
                    Picker("", selection: Binding(
                        get: { nth.weekday },
                        set: { binding.wrappedValue.nthWeekday?.weekday = $0 }
                    )) {
                        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
                        ForEach(1...7, id: \.self) { Text(names[$0 - 1]).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 62)
                }
            } else {
                innerRow("日期") {
                    Picker("", selection: Binding(
                        get: { binding.wrappedValue.monthDay ?? calendar.component(.day, from: anchor) },
                        set: { binding.wrappedValue.monthDay = $0 }
                    )) {
                        ForEach(1...31, id: \.self) { Text("\($0)日").tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 70)
                }
                FormHint("（当月无此日则跳过）")
            }
        }
    }

    private func endEditor(_ binding: Binding<RecurrenceSpec>) -> some View {
        VStack(alignment: .leading, spacing: FormMetrics.rowSpacing) {
            innerRow("结束重复") {
                Picker("", selection: Binding(
                    get: { binding.wrappedValue.end.mode },
                    set: { mode in
                        binding.wrappedValue.end.mode = mode
                        if mode == .date, binding.wrappedValue.end.date == nil {
                            binding.wrappedValue.end.date = Calendar.current.date(byAdding: .year, value: 1, to: anchor)
                        }
                        if mode == .count, binding.wrappedValue.end.count == nil {
                            binding.wrappedValue.end.count = 10
                        }
                    }
                )) {
                    Text("永不").tag(RecurrenceEndRule.Mode.never)
                    Text("于日期").tag(RecurrenceEndRule.Mode.date)
                    Text("次数").tag(RecurrenceEndRule.Mode.count)
                }
                .labelsHidden()
                .frame(width: 90)
            }
            switch binding.wrappedValue.end.mode {
            case .never:
                EmptyView()
            case .date:
                DatePicker("", selection: Binding(
                    get: { binding.wrappedValue.end.date ?? anchor },
                    set: { binding.wrappedValue.end.date = $0 }
                ), displayedComponents: [.date])
                    .labelsHidden()
                    .formControlSizing()
            case .count:
                Stepper("共 \(binding.wrappedValue.end.count ?? 1) 次",
                        value: Binding(
                            get: { binding.wrappedValue.end.count ?? 1 },
                            set: { binding.wrappedValue.end.count = $0 }
                        ), in: 1...999)
                    .controlSize(.small)
            }
        }
    }
}
