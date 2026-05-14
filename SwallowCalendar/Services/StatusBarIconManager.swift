//
//  StatusBarIconManager.swift
//  SwallowCalendar
//

import AppKit
import SwiftUI

@Observable
final class StatusBarIconManager {
    static let shared = StatusBarIconManager()

    var currentIcon: NSImage {
        didSet {
            statusItemButton?.image = currentIcon
        }
    }

    private(set) weak var statusItemButton: NSButton?

    private var refreshTimer: Timer?

    private var refreshInterval: TimeInterval {
        let settings = AppSettings.shared
        switch settings.iconStyle {
        case .calendarIcon:
            return 0
        case .solidDate, .strokeDate:
            return 60
        case .customFormat:
            let fmt = settings.customIconFormat
            if fmt.contains("ss") || fmt.contains("s") {
                return 1
            }
            if fmt.contains("mm") || fmt.contains("m") || fmt.contains("HH") || fmt.contains("H") {
                return 60
            }
            return 60
        }
    }

    private init() {
        let settings = AppSettings.shared
        let iconColor = NSColor(hexString: settings.accentColorHex) ?? .systemBlue
        currentIcon = Self.generateIcon(style: settings.iconStyle, customFormat: settings.customIconFormat, customFormatStyle: settings.customFormatStyle, iconColor: iconColor)
    }

    /// 绑定 statusItem 按钮（由 AppDelegate 在创建 statusItem 后调用）
    func bind(statusItem: NSStatusItem) {
        statusItemButton = statusItem.button
        statusItemButton?.image = currentIcon
        startRefreshTimer()
    }

    func updateIcon() {
        let settings = AppSettings.shared
        let iconColor = NSColor(hexString: settings.accentColorHex) ?? .systemBlue
        let icon = Self.generateIcon(style: settings.iconStyle, customFormat: settings.customIconFormat, customFormatStyle: settings.customFormatStyle, iconColor: iconColor)
        currentIcon = icon
    }

    func updateIconAndRestartTimer() {
        updateIcon()
        startRefreshTimer()
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil

        let interval = refreshInterval
        guard interval > 0 else { return }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.updateIcon()
        }
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private static func generateIcon(style: IconStyle, customFormat: String, customFormatStyle: AppSettings.CustomFormatStyle = .none, iconColor: NSColor = .systemBlue) -> NSImage {
        switch style {
        case .solidDate:
            return renderTextIcon(text: dayString(), filled: true, iconColor: iconColor)
        case .strokeDate:
            return renderTextIcon(text: dayString(), filled: false, iconColor: iconColor)
        case .calendarIcon:
            return renderCalendarIcon()
        case .customFormat:
            return renderCustomFormatIcon(format: customFormat, style: customFormatStyle, iconColor: iconColor)
        }
    }

    private static func dayString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        return formatter.string(from: Date())
    }

    private static func renderTextIcon(text: String, filled: Bool, iconColor: NSColor = .systemBlue) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        // 计算字体颜色（根据背景色亮度）
        let textColor: NSColor = isLightColor(iconColor) ? .black : .white

        if filled {
            // 实心日期：背景填充 + 居中日期
            let bgRect = NSRect(x: 0, y: 0, width: size.width, height: size.height)
            let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: 3, yRadius: 3)
            iconColor.setFill()
            bgPath.fill()

            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .bold),
                .foregroundColor: textColor,
                .paragraphStyle: paragraphStyle,
            ]
            // 文字垂直居中
            let textHeight: CGFloat = 12
            let textY = (size.height - textHeight) / 2
            let textRect = NSRect(x: 0, y: textY, width: size.width, height: textHeight)
            text.draw(in: textRect, withAttributes: attrs)
        } else {
            // 描边日期：透明背景 + 边框 + 白色日期
            let strokeRect = NSRect(x: 1, y: 1, width: size.width - 2, height: size.height - 2)
            let strokePath = NSBezierPath(roundedRect: strokeRect, xRadius: 3, yRadius: 3)
            strokePath.lineWidth = 1.5
            iconColor.setStroke()
            strokePath.stroke()

            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraphStyle,
            ]
            // 文字垂直居中
            let textHeight: CGFloat = 11
            let textY = (size.height - textHeight) / 2
            let textRect = NSRect(x: 0, y: textY, width: size.width, height: textHeight)
            text.draw(in: textRect, withAttributes: attrs)
        }

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    /// 判断颜色是否为浅色（用于决定文字颜色）
    private static func isLightColor(_ color: NSColor) -> Bool {
        guard let rgbColor = color.usingColorSpace(.sRGB) else { return false }
        let r = rgbColor.redComponent
        let g = rgbColor.greenComponent
        let b = rgbColor.blueComponent
        // 使用相对亮度公式
        let brightness = r * 0.299 + g * 0.587 + b * 0.114
        return brightness > 0.5
    }

    private static func renderCalendarIcon() -> NSImage {
        if let sfImage = NSImage(systemSymbolName: "calendar", accessibilityDescription: "Calendar") {
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            return sfImage.withSymbolConfiguration(config) ?? sfImage
        }
        return renderTextIcon(text: dayString(), filled: true)
    }

    private static func renderCustomFormatIcon(format: String, style: AppSettings.CustomFormatStyle, iconColor: NSColor) -> NSImage {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        let text = formatter.string(from: Date())
        
        // 使用系统菜单栏标准字体（13pt, regular）
        let fontSize: CGFloat = 13
        let font = NSFont.systemFont(ofSize: fontSize, weight: .regular)
        
        // 计算文本实际宽度
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let textSize = (text as NSString).size(withAttributes: attributes)
        
        // 宽度自适应：文本宽度 + 8pt 边距（左右各 4pt），最小 22pt
        let width = max(22, textSize.width + 8)
        let height: CGFloat = 22
        
        let size = NSSize(width: width, height: height)
        let image = NSImage(size: size)
        image.lockFocus()

        // 根据样式绘制背景
        let rect = NSRect(origin: .zero, size: size)
        switch style {
        case .none:
            // 无背景，直接绘制文字
            break
        case .solid:
            // 实心背景：使用主题色填充圆角矩形
            let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            iconColor.setFill()
            path.fill()
        case .stroke:
            // 描边背景：使用主题色绘制圆角矩形边框
            let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            path.lineWidth = 1.5
            iconColor.setStroke()
            path.stroke()
        }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        // 根据背景样式调整文字颜色
        let textColor: NSColor
        switch style {
        case .none:
            textColor = NSColor.labelColor
        case .solid:
            textColor = .white  // 实心背景用白色文字
        case .stroke:
            textColor = iconColor  // 描边样式用主题色文字
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle,
        ]

        // 文字垂直居中
        let textY = (height - textSize.height) / 2
        let textRect = NSRect(x: 0, y: textY, width: width, height: textSize.height)
        text.draw(in: textRect, withAttributes: attrs)
        image.unlockFocus()
        image.isTemplate = false  // 不再使用模板，保留颜色信息
        return image
    }
}

// MARK: - NSColor Hex Extension

extension NSColor {
    convenience init?(hexString: String) {
        let hex = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let scanner = Scanner(string: hex)
        var rgbValue: UInt64 = 0
        guard scanner.scanHexInt64(&rgbValue) else { return nil }

        let r = CGFloat((rgbValue & 0xFF0000) >> 16) / 255.0
        let g = CGFloat((rgbValue & 0x00FF00) >> 8) / 255.0
        let b = CGFloat(rgbValue & 0x0000FF) / 255.0

        self.init(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }
}
