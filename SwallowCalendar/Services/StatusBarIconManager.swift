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

    /// 倒计时徽章数据缓存（bug: reminder-starved-by-badge-expansion 配套节流）：
    /// 秒级 tick 命中缓存纯计算重绘不查库，查库降频到分钟边界/脏标记驱动
    private var countdownCache = CountdownBadgeCache()

    /// V-19：日期图标生成时的"当天零点"标记，用于按日短路——
    /// 实心/描边日期图标一天内内容不变，同日内定时触发的重绘直接跳过，跨天才重新渲染
    private var iconGenerationDate: Date?
    
    /// 图标缓存，避免重复创建相同样式的图标
    private let iconCache = NSCache<NSString, NSImage>()
    
    /// 缓存限制：最多缓存 50 个图标
    private let maxCacheCount = 50

    private var refreshInterval: TimeInterval {
        let settings = AppSettings.shared
        // badge-realtime-countdown B3：间隔策略抽至 StatusBarRefreshPolicy（徽标开启→1s 实时节奏）
        return StatusBarRefreshPolicy.computeRefreshInterval(
            iconStyle: settings.iconStyle,
            customFormat: settings.customIconFormat,
            badgeEnabled: settings.statusBarCountdownEnabled
        )
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
            self?.handleCachedEventsChanged()
        }
    }

    /// 缓存变更（D2/G7v2）：置脏标记并立即重绘——徽章路径经倒计时缓存节流，
    /// 脏标记使本次 updateIcon 恰好重查一次；同步风暴期间高频通知合并为
    /// 「置脏 + 每 tick 至多一次查询」（原实现每次通知都全量查库）
    private func handleCachedEventsChanged() {
        countdownCache.markDirty()
        updateIcon()
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
            let now = Date()
            // 配套节流（bug: reminder-starved-by-badge-expansion）：同一分钟内
            // 重复 tick 命中缓存纯计算重绘，不查库；跨分钟或脏标记才重查
            guard let start = self.countdownCache.nearestStart(now: now, query: { Self.nearestCountdownStart(now: now) }) else {
                // 无最近未完成事项：回退默认图标
                let iconColor = NSColor(hexString: settings.accentColorHex) ?? .systemBlue
                self.currentIcon = Self.generateIcon(style: settings.iconStyle, customFormat: settings.customIconFormat, customFormatStyle: settings.customFormatStyle, iconColor: iconColor, cache: self.iconCache)
                return
            }
            let text = CountdownFormatter.formatCountdown(remaining: start.timeIntervalSince(now))
            // 徽标外观与「菜单栏图标」样式逐项配合（实心→实心、描边→描边、日历→无背景、自定义格式→跟随自定义样式）
            let iconColor = NSColor(hexString: settings.accentColorHex) ?? .systemBlue
            let badgeStyle = settings.iconStyle.badgeStyle(customFormatStyle: settings.customFormatStyle)
            self.currentIcon = BadgeTextRenderer.render(text, style: badgeStyle, iconColor: iconColor)
        }
    }

    /// D2：取最近未完成用户事项的开始时间（nil = 无可显示事项）——查库核心
    /// 复用列表同款展开链路（bug: badge-recurring-task-invisible）：
    /// 循环任务 base.startDate 为过去首实例，直接查主表会被 startDate > now 排除，
    /// 而未来 occurrence 实例未落库——getEvents 在窗口内展开循环任务后统一返回
    @MainActor
    static func nearestCountdownStart(now: Date = Date()) -> Date? {
        let upperBound = now.addingTimeInterval(365 * 86400)
        let events = EventCacheService.shared.getEvents(from: now, to: upperBound)
        // getEvents 已按 startDate 升序返回；跳过节假日/有效期过滤由展开链路与列表保持一致
        guard let nearest = events.first(where: {
            $0.category == .user && !$0.isCompleted && ($0.startDate ?? .distantPast) > now
        }) else { return nil }
        return nearest.startDate
    }

    /// D2：取最近未完成用户事项的倒计时文案（nil = 无可显示事项）
    /// 文案计算基于 nearestCountdownStart，语义与拆分前一致（测试沿用）
    @MainActor
    static func latestCountdownText(now: Date = Date()) -> String? {
        guard let start = nearestCountdownStart(now: now) else { return nil }
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
        // 首次 fire 对齐到下一整秒边界（与列表倒计时定时器同相位，两侧数字同步跳动）；
        // repeats 模式下后续 fire = 新 fireDate + n*interval，整秒序列不漂移
        refreshTimer?.fireDate = Date().addingTimeInterval(CountdownPhaseSync.intervalToNextSecond())
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
        BadgeTextRenderer.render(customFormatter(for: format).string(from: Date()), style: style, iconColor: iconColor)
    }
}

// MARK: - 倒计时徽章数据缓存

/// 倒计时徽章查询节流缓存（bug: reminder-starved-by-badge-expansion 配套）：
/// 秒级 tick 只用缓存的最近事项日期纯计算重绘，查库降频到分钟边界 + 脏标记驱动；
/// 无事项状态（nil）同样缓存，避免无事项时每秒空查。值类型便于单测注入 query 计数
struct CountdownBadgeCache {
    private(set) var nearestStart: Date?
    private(set) var isDirty = false
    private var queriedMinute: Int = -1

    /// 缓存变更通知置脏：下个 tick 强制重查（高频通知天然防抖合并）
    mutating func markDirty() { isDirty = true }

    /// 取最近事项开始时间：同一分钟且未置脏时直接命中缓存，否则重查并记录
    /// - Parameter query: 查库闭包（注入便于测试统计查询次数）
    mutating func nearestStart(now: Date, query: () -> Date?) -> Date? {
        let minute = Int(now.timeIntervalSince1970 / 60)
        if isDirty || minute != queriedMinute {
            nearestStart = query()
            queriedMinute = minute
            isDirty = false
        }
        return nearestStart
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
