//
//  SettingsView.swift
//  SwallowCalendar
//

import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("通用", systemImage: "gearshape")
                }

            CalendarSettingsView()
                .tabItem {
                    Label("日历", systemImage: "calendar")
                }

            AboutSettingsView()
                .tabItem {
                    Label("关于", systemImage: "info.circle")
                }
        }
        .frame(width: 450, height: 380)
    }
}
