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

    /// 全天事项的周期档位限制（需求：仅支持「永不」「每小时」与自定义小时级；
    /// 其他档位灰显不可选——存量非法档仍显示原值，用户重选后收敛）
    var hourlyOnly: Bool = false

    /// 全天事项可选的周期档位
    static let hourlyOnlyAllowedPresets: Set<RecurrencePreset> = [.never, .hourly, .custom]

    var body: some View {
        VStack(alignment: .leading, spacing: FormMetrics.rowSpacing) {
            Picker("", selection: $preset) {
                ForEach(RecurrencePreset.allCases) { item in
                    Text(item.title).tag(item)
                        .disabled(hourlyOnly && !Self.hourlyOnlyAllowedPresets.contains(item))
                }
            }
            .labelsHidden()
            // 控件右对齐基准：下拉按固有宽度贴右，与开关/日期共用同一条基准线
            .formControlSizing()
            .frame(maxWidth: .infinity, alignment: .trailing)
            .onChange(of: preset) { _, newValue in
                guard newValue != .custom else {
                    // 自定义进入时保证有可编辑底稿（保留现有维度）
                    if spec == nil { spec = RecurrenceSpec.customDraft }
                    // 全天事项：自定义频率锁定小时级（底稿已是 hourly；存量其他频率钳回）
                    if hourlyOnly, spec?.frequency != .hourly {
                        spec?.frequency = .hourly
                    }
                    onChange()
                    return
                }
                spec = RecurrenceSpec.spec(for: newValue, anchor: anchor, current: spec)
                onChange()
            }

            if hourlyOnly {
                FormHint("全天事项仅支持「永不」「每小时」或自定义小时级重复")
            }

            if preset == .custom, spec != nil {
                customEditor
            } else if preset == .custom {
                Button("配置自定义规则") {
                    spec = RecurrenceSpec.customDraft
                    onChange()
                }
                .buttonStyle(.link)
            }

            // 提示条件复用映射层唯一判定：农历文案统一放在农历开关旁（lunarSystemHint），
            // 此处只处理非农历的「每小时仅本地」
            if !isLunar, let current = spec, RecurrenceEKMapper.isLocalOnly(current, isLunar: isLunar) {
                FormHint("每小时仅应用内生效；系统「提醒事项」中显示为「永不」")
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

    /// 农历开关旁的系统侧写入提示（唯一文案来源，界面只用系统提醒事项语言）
    /// - 条件与对账口径同源：`LunarMirrorPolicy.hint`
    /// - Returns: nil = 非农历且已设周期，不显示提示
    static func lunarSystemHint(isLunar: Bool, spec: RecurrenceSpec?) -> String? {
        switch LunarMirrorPolicy.hint(isLunar: isLunar, spec: spec) {
        case .systemMirrors:
            return "将在系统「提醒事项」中按公历日期创建对应提醒；本体规则在系统内显示为「永不」"
        case .localOnlyFrequency:
            return "当前频度下农历与公历等价，仅应用内生效；系统「提醒事项」中显示为「永不」"
        case .specMissing:
            return "未设置重复周期时农历不生效；请先在「重复」中选择周期"
        case nil:
            return nil
        }
    }

    // MARK: - 自定义面板

    @ViewBuilder
    private var customEditor: some View {
        let binding = Binding<RecurrenceSpec>(
            get: { spec ?? RecurrenceSpec.customDraft },
            set: { spec = $0; onChange() }
        )
        VStack(alignment: .leading, spacing: FormMetrics.rowSpacing) {
            innerRow("频率") {
                Picker("", selection: binding.frequency) {
                    ForEach(RecurrenceFrequency.allCases, id: \.self) { frequency in
                        Text("每\(frequency.displayName)").tag(frequency)
                            .disabled(hourlyOnly && frequency != .hourly)
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
        // 子面板占满整个控件列：左侧留 8pt 内缩，右侧不留，子控件才能与外层控件列同一右基准线
        .padding(.leading, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }

    /// 自定义面板内的行：统一 44pt 标签列，子控件贴齐面板右缘（即外层控件列的右基准线）
    private func innerRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: FormMetrics.labelControlGap) {
            FormLabel(label, width: FormMetrics.innerLabelWidth)
            content()
                .frame(maxWidth: .infinity, alignment: .trailing)
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
            // 等分控件占满子面板可用宽度即可保证右缘与基准线一致
            .frame(maxWidth: .infinity)

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
                    // 13pt 下「最后一个」固有宽约 91.5pt，留 4pt 余量避免出现「最后…」截断
                    .frame(maxWidth: 96)
                    Picker("", selection: Binding(
                        get: { nth.weekday },
                        set: { binding.wrappedValue.nthWeekday?.weekday = $0 }
                    )) {
                        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
                        ForEach(1...7, id: \.self) { Text(names[$0 - 1]).tag($0) }
                    }
                    .labelsHidden()
                    // 「周五」固有宽约 65.5pt
                    .frame(maxWidth: 70)
                }
                // 两个下拉整体贴右，与其它子行共用同一条右基准线
                .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                innerRow("日期") {
                    Picker("", selection: Binding(
                        get: { binding.wrappedValue.monthDay ?? calendar.component(.day, from: anchor) },
                        set: { binding.wrappedValue.monthDay = $0 }
                    )) {
                        ForEach(1...31, id: \.self) { Text("\($0)日").tag($0) }
                    }
                    .labelsHidden()
                    // 「31日」固有宽约 69.5pt，留余量避免末位被裁
                    .frame(width: 76)
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
                    // 结束日期同样贴右，与「结束重复」下拉共用右基准线
                    .frame(maxWidth: .infinity, alignment: .trailing)
            case .count:
                Stepper("共 \(binding.wrappedValue.end.count ?? 1) 次",
                        value: Binding(
                            get: { binding.wrappedValue.end.count ?? 1 },
                            set: { binding.wrappedValue.end.count = $0 }
                        ), in: 1...999)
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}
