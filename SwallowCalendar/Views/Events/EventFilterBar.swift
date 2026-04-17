//
//  EventFilterBar.swift
//  SwallowCalendar
//

import SwiftUI

struct EventFilterBar: View {
    @Binding var selectedFilter: EventFilterMode

    var body: some View {
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
                                    .fill(selectedFilter == mode ? Color.accentColor.opacity(0.15) : Color.clear)
                            )
                            .foregroundColor(selectedFilter == mode ? .accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
        }
        .padding(.vertical, 6)
    }
}
