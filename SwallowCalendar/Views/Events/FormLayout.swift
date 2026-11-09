//
//  FormLayout.swift
//  SwallowCalendar
//
//  新建/编辑共用的表单结构与控件：统一标签列、控件列、间距与分组卡片，
//  避免两个表单各自追加控件时各写一套间距/宽度
//

import SwiftUI
import AppKit

/// 内容自然高度测量值（表单弹窗自适应高度用；编辑与批量添加共用同一测量口径）
struct ContentHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 表单统一度量：新建与编辑表单只允许引用这一组取值
enum FormMetrics {
    /// 标签列宽（左对齐固定列宽，保证所有行控件起点一致）
    static let labelWidth: CGFloat = 64
    /// 内嵌子面板（周期/提醒自定义区）的标签列宽
    static let innerLabelWidth: CGFloat = 44
    /// 标签与控件间距
    static let labelControlGap: CGFloat = 8
    /// 同一分组内的行间距
    static let rowSpacing: CGFloat = 6
    /// 分组标题与内容间距
    static let sectionHeaderSpacing: CGFloat = 8
    /// 分组之间的间距
    static let sectionSpacing: CGFloat = 10
    /// 分组卡片内边距
    static let cardPaddingHorizontal: CGFloat = 12
    static let cardPaddingVertical: CGFloat = 10
    /// 嵌套子面板（周期/提醒自定义区）内的紧凑控件宽度
    static let compactControlWidth: CGFloat = 96
}

/// 表单标签：11pt 次要色、左对齐、固定列宽
struct FormLabel: View {
    let text: String
    let width: CGFloat

    init(_ text: String, width: CGFloat = FormMetrics.labelWidth) {
        self.text = text
        self.width = width
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .lineLimit(1)
            .frame(width: width, alignment: .leading)
    }
}

/// 表单行：左侧固定标签列 + 右侧控件列。
/// 控件列是全局唯一的右基准容器：所有行控件都贴齐到这条右边线，
/// 控件自身只负责按固有宽度绘制（formControlSizing），不再各自给固定宽度
struct FormRow<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: FormMetrics.labelControlGap) {
            FormLabel(label)
            content
                // 标签左、控件右：控件贴齐分组卡片右侧基准线（对齐 macOS 系统设置表单）
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

/// 语义分组卡片：统一标题、内边距与半透明材质背景（透出主面板玻璃，深浅色自适应）
struct FormSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FormMetrics.sectionHeaderSpacing) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            content
        }
        .padding(.horizontal, FormMetrics.cardPaddingHorizontal)
        .padding(.vertical, FormMetrics.cardPaddingVertical)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            // 半透明材质（浅色下不是一块纯白），
            // 与桌面面板 DesktopTodoPanelView 使用同一类 SwiftUI Material
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.thinMaterial)
        )
        .overlay(
            // 极淡描边：半透明背景上仍能看出卡片边界，深浅色都不过度
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

extension View {
    /// 表单行控件统一尺寸：按自身固有宽度布局，不用逐控件固定宽度。
    /// 右边缘由 FormRow 的 trailing 容器统一贴齐，所以日期选择器（以其最右侧上下箭头为准）、
    /// 开关、下拉、色点的右边缘都落在同一条基准线上
    func formControlSizing() -> some View {
        fixedSize(horizontal: true, vertical: false)
    }

    /// 表单开关统一尺寸：走系统控件尺寸（点击热区与动画随系统规则一起缩放），
    /// 不用 scaleEffect——缩放会把点击热区和动画一起缩掉，且与系统控件不一致
    func formToggleSizing() -> some View {
        controlSize(.small)
    }
}

/// 说明文字：统一 11pt 次要色，可换行
struct FormHint: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            // 单行/多行都限制在卡片内容区内自动换行，不允许用理想宽度把卡片顶宽
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 颜色选择（新建/编辑共用）：点选切换，再次点击同一颜色取消
struct FormColorSwatches: View {
    @Binding var selection: EventColor?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(EventColor.allCases, id: \.self) { color in
                Button {
                    selection = selection == color ? nil : color
                } label: {
                    Circle()
                        .fill(Color(hex: color.rawValue))
                        .frame(width: 16, height: 16)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.primary.opacity(0.85), lineWidth: 1.5)
                                .frame(width: 22, height: 22)
                                .opacity(selection == color ? 1 : 0)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        // 8 个色点合计 184pt，控件列 216pt 内可单行放下；
        // 显式贴右，保证与优先级/开关/日期落在同一条右侧基准线
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// 优先级选择（新建/编辑共用）
struct FormPriorityPicker: View {
    @Binding var selection: EventPriority

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(EventPriority.allCases, id: \.self) { priority in
                Text(priority.displayName).tag(priority)
            }
        }
        .labelsHidden()
        .formControlSizing()
    }
}
