//
//  SettingsWindowManager.swift
//  SwallowCalendar
//
//  管理设置窗口

import SwiftUI
import AppKit
import SwiftData

@MainActor
final class SettingsWindowManager {
    static let shared = SettingsWindowManager()
    
    var modelContainer: ModelContainer?
    var appSettings: AppSettings?
    private var settingsWindow: NSWindow?
    private var settingsWindowDelegate: SettingsWindowDelegate?
    private var isOpening = false
    
    private init() {}
    
    func openSettings() {
        // 防止重复打开
        guard !isOpening else { return }
        
        // 已有窗口则直接激活并置顶
        if let window = settingsWindow {
            window.level = NSWindow.Level.floating
            
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                
                if window.isVisible {
                    window.makeKeyAndOrderFront(nil)
                } else {
                    window.orderFront(nil)
                }
                
                window.makeKey()
                window.becomeKey()
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    window.level = NSWindow.Level.normal
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKey()
                    window.becomeKey()
                }
            }
            return
        }
        
        isOpening = true
        defer { isOpening = false }
        
        let settings = AppSettings.shared
        
        // 使用共享的 ModelContainer，确保数据一致性
        let container = modelContainer ?? AppDelegate.sharedModelContainer ?? createFallbackModelContainer()
        
        let settingsView = SettingsView()
            .environment(settings)
            .modelContainer(container)
            .tint(Color(hex: settings.accentColorHex))
        
        let hostingView = NSHostingView(rootView: settingsView.frame(minWidth: 450, minHeight: 400))
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 450),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "设置"
        window.contentView = hostingView
        window.center()
        window.level = NSWindow.Level.floating
        window.minSize = NSSize(width: 450, height: 400)
        window.maxSize = NSSize(width: 1200, height: 900)
        
        settingsWindowDelegate = SettingsWindowDelegate()
        window.delegate = settingsWindowDelegate
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        
        settingsWindow = window
        
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(self as Any?)
            window.becomeKey()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                window.level = NSWindow.Level.normal
                NSApp.activate(ignoringOtherApps: true)
                window.makeKey()
                window.becomeKey()
            }
        }
    }
    
    func windowDidClose() {
        settingsWindow = nil
    }
    
    private func createFallbackModelContainer() -> ModelContainer {
        let schema = Schema([CalendarPreference.self, CustomCalendarSource.self, CachedEvent.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            let errorDescription = error.localizedDescription
            // 仅在 schema 与旧数据库不匹配时删除旧库重建
            if errorDescription.contains("schema") || errorDescription.contains("migration") || errorDescription.contains("version") || errorDescription.contains("PersistentModel") {
                print("[SettingsWindowManager] Schema 不匹配，删除旧数据库重建: \(error)")
                Self.deleteDatabase()
                do {
                    return try ModelContainer(for: schema, configurations: [config])
                } catch {
                    fatalError("删除旧库后重建 ModelContainer 仍然失败: \(error)")
                }
            } else {
                fatalError("创建 ModelContainer 失败（非 schema 问题）: \(error)")
            }
        }
    }
    
    /// 删除 SwiftData 数据库文件
    private static func deleteDatabase() {
        let urls = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        guard let appSupport = urls.first else { return }
        
        let defaultDB = appSupport
            .appendingPathComponent("default.store", isDirectory: true)
        let defaultDBWal = appSupport
            .appendingPathComponent("default.store-wal", isDirectory: false)
        let defaultDBShm = appSupport
            .appendingPathComponent("default.store-shm", isDirectory: false)
        
        for url in [defaultDB, defaultDBWal, defaultDBShm] {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

private class SettingsWindowDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        SettingsWindowManager.shared.windowDidClose()
    }
}
