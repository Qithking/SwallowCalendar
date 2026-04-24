//
//  EventFilterBar.swift
//  SwallowCalendar
//

import SwiftUI

struct EventFilterBar: View {
    @Environment(AppSettings.self) private var appSettings
    @Binding var selectedFilter: EventFilterMode
    @State private var accentColor: Color = Color(hex: AppSettings.shared.accentColorHex)
    @State private var showSortMenu = false

    var body: some View {
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
            
            // 右侧：排序按钮
            Button {
                showSortMenu.toggle()
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showSortMenu, arrowEdge: .bottom) {
                sortMenuContent
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .onChange(of: appSettings.accentColorHex) { _, newColor in
            accentColor = Color(hex: newColor)
        }
    }
    
    // MARK: - Sort Menu Content
    
    private var sortMenuContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            // 排序字段
            ForEach(AppSettings.SortMode.allCases, id: \.self) { mode in
                Button {
                    appSettings.sortMode = mode
                    showSortMenu = false
                } label: {
                    HStack(spacing: 8) {
                        if appSettings.sortMode == mode {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10))
                                .foregroundColor(accentColor)
                                .frame(width: 12)
                        } else {
                            Spacer()
                                .frame(width: 12)
                        }
                        Text(mode.displayName)
                            .font(.system(size: 12))
                            .foregroundColor(.primary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
            }
            
            Divider()
            
            // 排序方向
            ForEach(AppSettings.SortOrder.allCases, id: \.self) { order in
                Button {
                    appSettings.sortOrder = order
                    showSortMenu = false
                } label: {
                    HStack(spacing: 8) {
                        if appSettings.sortOrder == order {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10))
                                .foregroundColor(accentColor)
                                .frame(width: 12)
                        } else {
                            Spacer()
                                .frame(width: 12)
                        }
                        Text(order.displayName)
                            .font(.system(size: 12))
                            .foregroundColor(.primary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
            }
        }
        .padding(.vertical, 4)
        .frame(minWidth: 120)
    }
}
