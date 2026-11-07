//
//  ReminderLeadPickerView.swift
//  SwallowCalendar
//
//  提前提醒共享组件：9 项预设（对齐 macOS 提醒事项）+ 自定义（提前/延后 × 数量 × 单位）
//

import SwiftUI

/// 自定义提前提醒方向：提前 / 延后
enum ReminderLeadDirection: String, CaseIterable, Identifiable {
    case before
    case after

    var id: String { rawValue }
    var title: String { self == .before ? "提前" : "延后" }
    /// 写入 offsets 的符号：提前为正、延后为负（alertTime = startDate - offset*60）
    var sign: Int { self == .before ? 1 : -1 }
}

/// 自定义提前提醒单位；月固定 30 天，保证分钟数可逆与跨端稳定
enum ReminderLeadUnit: String, CaseIterable, Identifiable {
    case minute
    case hour
    case day
    case week
    case month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .minute: return "分钟"
        case .hour: return "小时"
        case .day: return "天"
        case .week: return "周"
        case .month: return "月"
        }
    }

    var minutesPerUnit: Int {
        switch self {
        case .minute: return 1
        case .hour: return 60
        case .day: return 1440
        case .week: return 10080
        case .month: return 43200
        }
    }
}

/// 9 项预设（顺序与提醒事项 App 一致：无 → 1天前 … → 自定义）
enum ReminderLeadPreset: String, CaseIterable, Identifiable {
    case none
    case oneDay
    case twoDays
    case oneWeek
    case twoWeeks
    case oneMonth
    case threeMonths
    case sixMonths
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "无"
        case .oneDay: return "1天前"
        case .twoDays: return "2天前"
        case .oneWeek: return "1周前"
        case .twoWeeks: return "2周前"
        case .oneMonth: return "1个月前"
        case .threeMonths: return "3个月前"
        case .sixMonths: return "6个月前"
        case .custom: return "自定义"
        }
    }

    /// 预设对应的提前分钟数；无/自定义返回 nil
    var offsetMinutes: Int? {
        switch self {
        case .none, .custom: return nil
        case .oneDay: return 1440
        case .twoDays: return 2880
        case .oneWeek: return 10080
        case .twoWeeks: return 20160
        case .oneMonth: return 43200
        case .threeMonths: return 129600
        case .sixMonths: return 259200
        }
    }

    /// 由当前 offsets 反推下拉选中项：单个非零档命中预设则选中它，多档/非预设为自定义
    static func resolve(offsets: [Int]) -> ReminderLeadPreset {
        let nonZero = Set(offsets.filter { $0 != 0 })
        guard !nonZero.isEmpty else { return .none }
        guard nonZero.count == 1, let value = nonZero.first else { return .custom }
        return allCases.first { $0.offsetMinutes == value } ?? .custom
    }

    /// 档位文案（用于多级 chip 与自定义列表）：0=到点、正=前、负=后
    static func label(for offset: Int) -> String {
        if offset == 0 { return "到点" }
        let magnitude = abs(offset)
        let amount: String
        if magnitude % 43200 == 0 {
            amount = "\(magnitude / 43200)个月"
        } else if magnitude % 1440 == 0 {
            amount = "\(magnitude / 1440)天"
        } else if magnitude % 60 == 0 {
            amount = "\(magnitude / 60)小时"
        } else {
            amount = "\(magnitude)分钟"
        }
        return amount + (offset > 0 ? "前" : "后")
    }
}

/// 提前提醒选择器：9 项预设下拉 + 自定义面板 + 已有多级档位
struct ReminderLeadPickerView: View {
    @Binding var offsets: [Int]

    @State private var customDirection: ReminderLeadDirection = .before
    @State private var customCountText = "1"
    @State private var customUnit: ReminderLeadUnit = .hour
    /// 用户主动切到「自定义」时保持面板展开，避免 offsets 仍命中预设导致下拉回弹
    @State private var isCustomMode = false

    /// 安全上限（365 天），仅防溢出，不是业务档位
    private let maxLeadMinutes = CachedEvent.maxReminderLeadMinutes

    private var selectedPreset: ReminderLeadPreset {
        isCustomMode ? .custom : ReminderLeadPreset.resolve(offsets: offsets)
    }

    private var presetBinding: Binding<ReminderLeadPreset> {
        Binding(
            get: { selectedPreset },
            set: { apply($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FormMetrics.rowSpacing) {
            Picker("", selection: presetBinding) {
                ForEach(ReminderLeadPreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .labelsHidden()
            // 控件右对齐基准：下拉按固有宽度贴右，与开关/日期共用同一条基准线
            .formControlSizing()
            .frame(maxWidth: .infinity, alignment: .trailing)

            // 自定义或多级档位：展示方向/数量/单位与现有档位
            if selectedPreset == .custom {
                customEditor
                    // 展开行同样贴齐右侧基准线
                    .frame(maxWidth: .infinity, alignment: .trailing)
                if !offsets.isEmpty {
                    offsetChips
                }
            }
        }
        // 展开态与收起态都占满控件列，保证展开不撑破整行
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: offsets) { _, newValue in
            // 外部清空（如新建表单重置）时退出自定义态，避免下一条任务残留面板
            if newValue.isEmpty { isCustomMode = false }
        }
    }

    // MARK: - 子视图

    private var customEditor: some View {
        HStack(spacing: 6) {
            Picker("", selection: $customDirection) {
                ForEach(ReminderLeadDirection.allCases) { direction in
                    Text(direction.title).tag(direction)
                }
            }
            .labelsHidden()
            .frame(width: 56)

            TextField("数量", text: $customCountText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .frame(width: 34)
                .multilineTextAlignment(.trailing)

            Picker("", selection: $customUnit) {
                ForEach(ReminderLeadUnit.allCases) { unit in
                    Text(unit.title).tag(unit)
                }
            }
            .labelsHidden()
            .frame(width: 52)

            Button(action: addCustomOffset) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)
            .help("添加自定义提前/延后档位（上限 365 天）")
        }
    }

    private var offsetChips: some View {
        // 自适应网格换行：多档位不会横向溢出撑破表单
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 54), spacing: 4, alignment: .leading)],
            alignment: .leading,
            spacing: 4
        ) {
            ForEach(offsets.sorted(), id: \.self) { offset in
                Button {
                    offsets.removeAll { $0 == offset }
                } label: {
                    Text(ReminderLeadPreset.label(for: offset))
                        .font(.system(size: 10.5, weight: .medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.accentColor.opacity(0.16))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.accentColor, lineWidth: 1.2)
                        )
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .help("点击移除该档位")
            }
        }
    }

    // MARK: - 交互

    /// 预设切换：无=清空提前档；预设=替换为单档；自定义=保留现值等待添加
    private func apply(_ preset: ReminderLeadPreset) {
        switch preset {
        case .none:
            isCustomMode = false
            offsets = []
        case .custom:
            isCustomMode = true
        default:
            isCustomMode = false
            if let minutes = preset.offsetMinutes {
                offsets = [minutes]
            }
        }
    }

    /// 添加自定义档位：数量 × 单位，按方向取符号，超上限拒绝
    private func addCustomOffset() {
        guard let count = Int(customCountText), count > 0 else { return }
        let minutes = count * customUnit.minutesPerUnit
        guard minutes <= maxLeadMinutes else { return }
        let signed = customDirection.sign * minutes
        if !offsets.contains(signed) {
            offsets = Array(Set(offsets + [signed])).sorted()
        }
    }
}
