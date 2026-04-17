//
//  StatusBarIconManager.swift
//  SwallowCalendar
//

import AppKit
import SwiftUI

@Observable
final class StatusBarIconManager {
    static let shared = StatusBarIconManager()

    var currentIcon: NSImage

    private var refreshTimer: Timer?

    private init() {
        currentIcon = Self.generateIcon(style: .solidDate, customFormat: "d")
        startDayChangeTimer()
    }

    func updateIcon() {
        let settings = AppSettings.shared
        let icon = Self.generateIcon(style: settings.iconStyle, customFormat: settings.customIconFormat)
        currentIcon = icon
    }

    private func startDayChangeTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.updateIcon()
        }
    }

    private static func generateIcon(style: IconStyle, customFormat: String) -> NSImage {
        switch style {
        case .solidDate:
            return renderTextIcon(text: dayString(), filled: true)
        case .strokeDate:
            return renderTextIcon(text: dayString(), filled: false)
        case .calendarIcon:
            return renderCalendarIcon()
        case .customFormat:
            return renderCustomFormatIcon(format: customFormat)
        }
    }

    private static func dayString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        return formatter.string(from: Date())
    }

    private static func renderTextIcon(text: String, filled: Bool) -> NSImage {
        let size = NSSize(width: 22, height: 22)
        let image = NSImage(size: size)
        image.lockFocus()

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        let fontSize: CGFloat = filled ? 14 : 13
        let fontWeight: NSFont.Weight = filled ? .bold : .regular

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: fontWeight),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle,
        ]

        let textRect = NSRect(x: 0, y: 2, width: size.width, height: size.height - 2)
        text.draw(in: textRect, withAttributes: attrs)
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private static func renderCalendarIcon() -> NSImage {
        if let sfImage = NSImage(systemSymbolName: "calendar", accessibilityDescription: "Calendar") {
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            return sfImage.withSymbolConfiguration(config) ?? sfImage
        }
        return renderTextIcon(text: dayString(), filled: true)
    }

    private static func renderCustomFormatIcon(format: String) -> NSImage {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        let text = formatter.string(from: Date())
        let fontSize: CGFloat = text.count > 3 ? 10 : 14
        let size = NSSize(width: max(22, CGFloat(text.count) * 10 + 4), height: 22)
        let image = NSImage(size: size)
        image.lockFocus()

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle,
        ]

        let textRect = NSRect(x: 0, y: 2, width: size.width, height: size.height - 2)
        text.draw(in: textRect, withAttributes: attrs)
        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}
