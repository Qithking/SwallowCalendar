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
        app.run()
    }
}
