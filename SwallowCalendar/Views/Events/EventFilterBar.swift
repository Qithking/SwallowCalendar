//
//  EventFilterBar.swift
//  SwallowCalendar
//

import SwiftUI

struct EventFilterBar: View {
    @Environment(AppSettings.self) private var appSettings
    @Binding var selectedFilter: EventFilterMode
    // V-18：直接读 appSettings 主题色，替代 @State 复制 + onChange 同步
    private var accentColor: Color { Color(hex: appSettings.accentColorHex) }

    var body: some View {
        // @Bindable 局部投影：appSettings 为 @Observable 环境，取 $binding 需经 Bindable
        @Bindable var appSettings = appSettings
        HStack(spacing: 8) {
            // 左侧：过滤选项
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(EventFilterMode.allCases, id: \.self) { mode in
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedFilter = mode
                            }
                        } label: {
                            Text(mode.rawValue)
                                .font(.system(size: 11))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(selectedFilter == mode ? accentColor.opacity(0.15) : Color.clear)
                                )
                                .foregroundColor(selectedFilter == mode ? accentColor : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
            }
            
            Spacer()
            
            // 右侧：排序菜单（改用系统 NSMenu 承载：macOS 26 上 NSPopover 的
            // Liquid Glass 材质呈现时内存跳升明显——用户实测仅排序弹框异常、
            // 自研窗口弹窗正常；系统菜单无该开销且更符合菜单栏应用规范）
            Menu {
                // 排序字段：Picker 内联渲染，当前项勾选由系统绘制
                // （NSMenu 菜单项不渲染 SwiftUI Label 图标，Button + checkmark 方式勾选无效）
                Picker("排序字段", selection: $appSettings.sortMode) {
                    ForEach(AppSettings.SortMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.inline)

                Divider()

                // 排序方向
                Picker("排序方向", selection: $appSettings.sortOrder) {
                    ForEach(AppSettings.SortOrder.allCases, id: \.self) { order in
                        Text(order.displayName).tag(order)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}
