//
//  EventFilterBar.swift
//  SwallowCalendar
//

import SwiftUI

struct EventFilterBar: View {
    @Environment(AppSettings.self) private var appSettings
    @Binding var selectedFilter: EventFilterMode
    @State private var accentColor: Color = Color(hex: AppSettings.shared.accentColorHex)

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
            
            // 右侧：排序菜单
            Menu {
                ForEach(AppSettings.SortMode.allCases, id: \.self) { mode in
                    Button {
                        appSettings.sortMode = mode
                    } label: {
                        HStack {
                            if appSettings.sortMode == mode {
                                Image(systemName: "checkmark")
                                    .foregroundColor(accentColor)
                            }
                            Text(mode.displayName)
                        }
                    }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .onChange(of: appSettings.accentColorHex) { _, newColor in
            accentColor = Color(hex: newColor)
        }
    }
}
