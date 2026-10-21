//
//  SwallowCalendarApp.swift
//  SwallowCalendar
//

import AppKit

@main
enum SwallowCalendarApp {
    // NSApplication 对 delegate 是弱引用，必须静态强持有防止释放
    private static let appDelegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = appDelegate
        // N-14：纯 SPM swift run 无 Info.plist（LSUIElement 缺失会显示 Dock 图标），
        // 代码侧设置等效策略；Xcode 构建已有 LSUIElement，此处幂等无副作用
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
