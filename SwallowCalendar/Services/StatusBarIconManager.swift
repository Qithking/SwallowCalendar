//
//  StatusBarIconManager.swift
//  SwallowCalendar
//

import AppKit
import SwiftUI
import SwiftData

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

    /// V-19：日期图标生成时的"当天零点"标记，用于按日短路——
    /// 实心/描边日期图标一天内内容不变，同日内定时触发的重绘直接跳过，跨天才重新渲染
    private var iconGenerationDate: Date?
    
    /// 图标缓存，避免重复创建相同样式的图标
    private let iconCache = NSCache<NSString, NSImage>()
    
    /// 缓存限制：最多缓存 50 个图标
    private let maxCacheCount = 50

    private var refreshInterval: TimeInterval {
        let settings = AppSettings.shared
        let base: TimeInterval
        switch settings.iconStyle {
        case .calendarIcon:
            base = 0
        case .solidDate, .strokeDate:
            base = 60
        case .customFormat:
            let fmt = settings.customIconFormat
            if fmt.contains("ss") || fmt.contains("s") {
                base = 1
            } else {
                // mm/HH 及纯日期格式均为分钟级精度，60 秒刷新即可
                base = 60
            }
        }
        // D2：徽标开启时兜底刷新间隔取 max(30, 原间隔)——秒级 customFormat 也不压过
        // 徽标更新节奏；即时刷新以 CachedEventsChanged 通知为主，定时器仅兜底
        guard settings.statusBarCountdownEnabled else { return base }
        return max(30, base)
    }

    private init() {
        iconCache.countLimit = maxCacheCount
        let settings = AppSettings.shared
        let iconColor = NSColor(hexString: settings.accentColorHex) ?? .systemBlue
        currentIcon = Self.generateIcon(style: settings.iconStyle, customFormat: settings.customIconFormat, customFormatStyle: settings.customFormatStyle, iconColor: iconColor, cache: iconCache)
        // D2/G7v2：订阅缓存变更通知，收到即刷新（不重启定时器），30s 定时器兜底
        NotificationCenter.default.addObserver(
            forName: .cachedEventsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateIcon()
        }
    }

    /// 绑定 statusItem 按钮（由 AppDelegate 在创建 statusItem 后调用）
    func bind(statusItem: NSStatusItem) {
        statusItemButton = statusItem.button
        statusItemButton?.image = currentIcon
        startRefreshTimer()
    }

    func updateIcon() {
        let settings = AppSettings.shared

        // D2：徽标开启时渲染最近未完成事项倒计时，无事项回退默认图标
        if settings.statusBarCountdownEnabled {
            renderCountdownBadge(settings: settings)
            return
        }

        // V-19：日期类图标（实心/描边日期）一天内内容不变，同日内跳过重绘，
        // 跨天（标记为 nil 或非今天）才重新生成
        if settings.iconStyle == .solidDate || settings.iconStyle == .strokeDate {
            let today = Calendar.current.startOfDay(for: Date())
            if let generated = iconGenerationDate, generated == today {
                return
            }
            iconGenerationDate = today
        }

        let iconColor = NSColor(hexString: settings.accentColorHex) ?? .systemBlue
        let icon = Self.generateIcon(style: settings.iconStyle, customFormat: settings.customIconFormat, customFormatStyle: settings.customFormatStyle, iconColor: iconColor, cache: iconCache)
        currentIcon = icon
    }

    /// D2：查询最近未完成事项并渲染倒计时徽标
    /// G3：EventCacheService 为 @MainActor，而本方法由 RunLoop Timer / 通知触发，
    /// 徽标查询经 Task { @MainActor } 派发，避免跨 actor 访问缓存服务
    private func renderCountdownBadge(settings: AppSettings) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let text = Self.latestCountdownText() else {
                // 无最近未完成事项：回退默认图标
                let iconColor = NSColor(hexString: settings.accentColorHex) ?? .systemBlue
                self.currentIcon = Self.generateIcon(style: settings.iconStyle, customFormat: settings.customIconFormat, customFormatStyle: settings.customFormatStyle, iconColor: iconColor, cache: self.iconCache)
                return
            }
            // 徽标外观跟随自定义格式样式设置（无背景/实心/描边）
            let iconColor = NSColor(hexString: settings.accentColorHex) ?? .systemBlue
            self.currentIcon = Self.renderBadgeText(text, style: settings.customFormatStyle, iconColor: iconColor)
        }
    }

    /// D2：取最近未完成用户事项的倒计时文案（nil = 无可显示事项）
    /// 复用 B-27 谓词粗筛模式：粗筛限定用户分类 + 未完成 + startDate ∈ (now, now+365 天]，
    /// 升序取第一个即最近事项；精确判定由谓词完成
    @MainActor
    private static func latestCountdownText(now: Date = Date()) -> String? {
        guard let context = EventCacheService.shared.context else { return nil }
        let upperBound = now.addingTimeInterval(365 * 86400)
        let userCategory = "用户"
        let distantPast = Date.distantPast
        let descriptor = FetchDescriptor<CachedEvent>(
            predicate: #Predicate {
                $0.categoryRaw == userCategory &&
                !$0.isCompleted &&
                $0.startDate != nil &&
                ($0.startDate ?? distantPast) > now &&
                ($0.startDate ?? distantPast) <= upperBound
            },
            sortBy: [SortDescriptor(\.startDate)]
        )
        guard let nearest = try? context.fetch(descriptor).first,
              let start = nearest.startDate else { return nil }
        return CountdownFormatter.formatCountdown(remaining: start.timeIntervalSince(now))
    }

    func updateIconAndRestartTimer() {
        // V-19：设置变更（样式/颜色/格式）后强制重绘，清除按日短路标记
        iconGenerationDate = nil
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
        // V-19：加入 common mode，菜单展开/拖动等 tracking 期间定时器仍能触发，
        // 避免跨天后图标停留在旧日期直到交互结束
        if let timer = refreshTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private static func generateIcon(style: IconStyle, customFormat: String, customFormatStyle: AppSettings.CustomFormatStyle = .none, iconColor: NSColor = .systemBlue, cache: NSCache<NSString, NSImage>? = nil) -> NSImage {
        // 生成缓存 key（日期相关的图标不缓存，因为每天都变）
        let shouldCache: Bool
        let cacheKey: String
        
        switch style {
        case .solidDate, .strokeDate:
            // 日期图标每天变化，不缓存
            shouldCache = false
            cacheKey = ""
        case .calendarIcon:
            shouldCache = true
            cacheKey = "calendarIcon_\(iconColor.hexString)"
        case .customFormat:
            shouldCache = !customFormat.contains("d") && !customFormat.contains("dd") && !customFormat.contains("D") && !customFormat.contains("DD")
            cacheKey = "custom_\(customFormat)_\(customFormatStyle.rawValue)_\(iconColor.hexString)"
        }
        
        // 尝试从缓存获取
        if shouldCache, let cache = cache, let cachedIcon = cache.object(forKey: cacheKey as NSString) {
            return cachedIcon
        }
        
        // 生成新图标
        let icon: NSImage
        switch style {
        case .solidDate:
            icon = renderTextIcon(text: dayString(), filled: true, iconColor: iconColor)
        case .strokeDate:
            icon = renderTextIcon(text: dayString(), filled: false, iconColor: iconColor)
        case .calendarIcon:
            icon = renderCalendarIcon()
        case .customFormat:
            icon = renderCustomFormatIcon(format: customFormat, style: customFormatStyle, iconColor: iconColor)
        }
        
        // 缓存图标
        if shouldCache, let cache = cache {
            cache.setObject(icon, forKey: cacheKey as NSString)
        }
        
        return icon
    }

    // 日期数字格式化器（固定格式，复用避免重复创建；仅主线程图标渲染时使用）
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        return formatter
    }()

    private static func dayString() -> String {
        dayFormatter.string(from: Date())
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

    // 自定义格式格式化器缓存：格式字符串未变化时复用（仅主线程使用）
    private static var customFormatCache: (format: String, formatter: DateFormatter)?

    private static func customFormatter(for format: String) -> DateFormatter {
        if let cache = customFormatCache, cache.format == format {
            return cache.formatter
        }
        let formatter = DateFormatter()
        formatter.dateFormat = format
        customFormatCache = (format, formatter)
        return formatter
    }

    private static func renderCustomFormatIcon(format: String, style: AppSettings.CustomFormatStyle, iconColor: NSColor) -> NSImage {
        renderBadgeText(customFormatter(for: format).string(from: Date()), style: style, iconColor: iconColor)
    }

    /// D2：按给定文本渲染宽度自适应的菜单栏图标（自定义格式图标与倒计时徽标共用）
    private static func renderBadgeText(_ text: String, style: AppSettings.CustomFormatStyle, iconColor: NSColor) -> NSImage {
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
    
    var hexString: String {
        guard let rgbColor = usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int(round(rgbColor.redComponent * 255))
        let g = Int(round(rgbColor.greenComponent * 255))
        let b = Int(round(rgbColor.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
