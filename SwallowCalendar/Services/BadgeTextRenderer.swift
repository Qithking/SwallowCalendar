//
//  BadgeTextRenderer.swift
//  SwallowCalendar
//
//  徽标文本渲染器（badge-realtime-countdown B4；bug-badge-jitter-ugly 重设计）
//  等宽数字防抖动、18pt 高与日期图标统一、无背景样式 template 化适配深浅菜单栏
//

import AppKit

enum BadgeTextRenderer {
    /// 徽标字号：与日期图标（renderTextIcon 11pt）一致，避免徽标文本视觉偏大
    private static let fontSize: CGFloat = 11

    /// 画布高度：与日期图标（renderTextIcon 18×18）一致，避免 22pt 撑满菜单栏
    private static let iconHeight: CGFloat = 18

    /// 最小画布宽度
    private static let minWidth: CGFloat = 22

    /// 按样式返回字体：实心背景→bold（对齐实心日期），描边/无背景→regular；
    /// 等宽数字变体：同字符数文本宽度恒定，倒计时秒级刷新不推挤相邻菜单栏图标
    static func font(for style: AppSettings.CustomFormatStyle) -> NSFont {
        let weight: NSFont.Weight = style == .solid ? .bold : .regular
        return NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: weight)
    }

    /// 渲染宽度自适应徽标图标：字形 ink 中线对齐画布中线（字形级垂直居中）
    static func render(_ text: String, style: AppSettings.CustomFormatStyle, iconColor: NSColor) -> NSImage {
        let font = Self.font(for: style)
        let textSize = (text as NSString).size(withAttributes: [.font: font])

        // 宽度自适应：文本宽度 + 8pt 边距（左右各 4pt）；等宽数字下同格式宽度恒定
        let width = max(minWidth, ceil(textSize.width) + 8)
        let size = NSSize(width: width, height: iconHeight)
        let image = NSImage(size: size)
        image.lockFocus()

        // 根据样式绘制背景（描边与日期图标一致内缩 1pt，避免线宽外半被裁）
        switch style {
        case .none:
            break
        case .solid:
            let path = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 3, yRadius: 3)
            iconColor.setFill()
            path.fill()
        case .stroke:
            let strokeRect = NSRect(x: 1, y: 1, width: size.width - 2, height: size.height - 2)
            let path = NSBezierPath(roundedRect: strokeRect, xRadius: 3, yRadius: 3)
            path.lineWidth = 1.5
            iconColor.setStroke()
            path.stroke()
        }

        // 文字颜色：无背景→黑（template mask）；实心→按背景亮度取黑/白；描边→主题色
        let textColor: NSColor
        switch style {
        case .none:
            textColor = .black
        case .solid:
            textColor = isLightColor(iconColor) ? .black : .white
        case .stroke:
            textColor = iconColor
        }

        // CoreText：按字形 ink bounds 精确定位 baseline，实现字形级垂直居中
        // （不依赖 lineHeight 的线性居中，数字/冒号/CJK 混排均对齐画布中线）
        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: textColor]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        let inkBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let baselineY = iconHeight / 2 - (inkBounds.minY + inkBounds.maxY) / 2

        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let typoWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let context = NSGraphicsContext.current!.cgContext
        context.textPosition = CGPoint(x: (size.width - typoWidth) / 2, y: baselineY)
        CTLineDraw(line, context)

        image.unlockFocus()
        // 无背景纯文字走 template：系统按菜单栏深浅自动反色，对比度始终正确；
        // 实心/描边需保留主题色信息，不走 template
        image.isTemplate = (style == .none)
        return image
    }

    /// 判断颜色是否为浅色（相对亮度 > 0.5，与 StatusBarIconManager.isLightColor 同公式）
    private static func isLightColor(_ color: NSColor) -> Bool {
        guard let rgbColor = color.usingColorSpace(.sRGB) else { return false }
        let brightness = rgbColor.redComponent * 0.299 + rgbColor.greenComponent * 0.587 + rgbColor.blueComponent * 0.114
        return brightness > 0.5
    }
}
