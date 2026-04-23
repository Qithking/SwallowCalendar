//
//  SwallowCalendarApp.swift
//  SwallowCalendar
//

import SwiftUI
import SwiftData
import AppKit

@main
struct SwallowCalendarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        // 使用 Settings 场景来保持应用运行，但不显示任何窗口
        Settings {
            EmptyView()
        }
    }
}
