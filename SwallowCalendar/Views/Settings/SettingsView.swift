//
//  SettingsView.swift
//  SwallowCalendar
//

import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var appSettings
    
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("通用", systemImage: "gearshape")
                }

            CalendarSettingsView()
                .tabItem {
                    Label("同步", systemImage: "arrow.triangle.2.circlepath")
                }
            
            DataExportSettingsView()
                .tabItem {
                    Label("数据", systemImage: "square.and.arrow.up.on.square")
                }

            AboutSettingsView()
                .tabItem {
                    Label("关于", systemImage: "info.circle")
                }
        }
        .frame(minWidth: 450, minHeight: 400)
        .tint(Color(hex: appSettings.accentColorHex))
    }
}
