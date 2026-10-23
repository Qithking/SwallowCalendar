//
//  BadgeTextRenderer.swift
//  SwallowCalendar
//
//  徽标文本渲染器（badge-realtime-countdown B4）
//  自定义格式图标与倒计时徽标共用：11pt 与日期图标视觉一致、字形级垂直居中
//

import AppKit

enum BadgeTextRenderer {
    /// 徽标字号：与日期图标（renderTextIcon 11pt）一致，避免徽标文本视觉偏大
    private static let fontSize: CGFloat = 11

    /// 按样式返回字体：实心背景→bold（对齐实心日期），描边/无背景→regular
    static func font(for style: AppSettings.CustomFormatStyle) -> NSFont {
        let weight: NSFont.Weight = style == .solid ? .bold : .regular
        return NSFont.systemFont(ofSize: fontSize, weight: weight)
    }

    /// 渲染宽度自适应徽标图标：字形 ink 中线对齐画布中线（字形级垂直居中）
    static func render(_ text: String, style: AppSettings.CustomFormatStyle, iconColor: NSColor) -> NSImage {
        let font = Self.font(for: style)
        let textSize = (text as NSString).size(withAttributes: [.font: font])

        // 宽度自适应：文本宽度 + 8pt 边距（左右各 4pt），最小 22pt
        let width = max(22, ceil(textSize.width) + 8)
        let height: CGFloat = 22

        let size = NSSize(width: width, height: height)
        let image = NSImage(size: size)
        image.lockFocus()

        // 根据样式绘制背景
        let rect = NSRect(origin: .zero, size: size)
        switch style {
        case .none:
            break
        case .solid:
            let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            iconColor.setFill()
            path.fill()
        case .stroke:
            let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            path.lineWidth = 1.5
            iconColor.setStroke()
            path.stroke()
        }

        // 根据背景样式调整文字颜色
        let textColor: NSColor
        switch style {
        case .none:
            textColor = NSColor.labelColor
        case .solid:
            textColor = .white
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
        let baselineY = height / 2 - (inkBounds.minY + inkBounds.maxY) / 2

        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let typoWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let context = NSGraphicsContext.current!.cgContext
        context.textPosition = CGPoint(x: (size.width - typoWidth) / 2, y: baselineY)
        CTLineDraw(line, context)

        image.unlockFocus()
        image.isTemplate = false  // 保留颜色信息
        return image
    }
}
