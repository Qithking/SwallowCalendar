//
//  CalendarGridView.swift
//  SwallowCalendar
//

import SwiftUI
import SwiftData
import EventKit
import AppKit

// MARK: - Hover 弹窗自管窗口（替代 NSPopover）

/// NSPopover 在屏幕右缘空间不足时会被系统强制 reposition（弹窗整体左移、
/// 箭头仍指锚点格子），观感为"错位一格以上"。改为自管 borderless 窗口：
/// 优先在锚点左侧、垂直居中显示（弹窗主体位于主面板外侧，箭头在右缘指向锚点），
/// 左侧空间不足时 fallback 到垂直布局（悬停锚点上方、放不下翻转到下方）。
/// 窗口忽略鼠标事件：点击全部穿透到主面板，hover 离开自然驱动关闭（等效 transient）。
@MainActor
final class CellPopoverWindowController {
    private var window: NSWindow?

    /// 是否正在显示（供 presenter 去重，避免 SwiftUI 更新时重复建窗）
    var isShowing: Bool { window != nil }

    /// content: (箭头布局信息, 内容固定宽度) -> 弹窗视图。
    /// 箭头只做平移不影响内容尺寸，先用占位值测量，布局后再构建最终视图；
    /// fixedWidth 非 nil 时内容按固定宽度换行（长文本场景，见 maxContentWidth）
    func show(
        content: (PopoverLayoutInfo, CGFloat?) -> some View,
        anchorInScreen: NSRect,
        baseWindow: NSWindow?,
        maxContentWidth: CGFloat? = nil
    ) {
        close()

        // 1. 测量内容尺寸：fittingSize 是"理想"尺寸（长文本按最宽单行计），
        //    超出 maxContentWidth 时按固定宽度重测（换行后的完整高度），
        //    否则窗口高度不足、渲染时文本提案过矮被省略。
        //    占位先按左侧模式（右缘箭头）；fallback 垂直模式时 padding 方向不同需重测
        var placeholder = PopoverLayoutInfo(arrowSide: .right, tip: 0)
        var fixedWidth: CGFloat?
        var contentSize = NSHostingView(rootView: content(placeholder, nil)).fittingSize
        if let maxContentWidth, contentSize.width > maxContentWidth {
            fixedWidth = maxContentWidth
            contentSize = NSHostingView(rootView: content(placeholder, fixedWidth)).fittingSize
        }
        var (frame, arrowSide) = Self.layout(
            size: contentSize,
            anchor: anchorInScreen,
            screen: baseWindow?.screen ?? NSScreen.main
        )
        if arrowSide != .right {
            placeholder = PopoverLayoutInfo(arrowSide: .bottom, tip: 0)
            contentSize = NSHostingView(rootView: content(placeholder, fixedWidth)).fittingSize
            (frame, arrowSide) = Self.layout(
                size: contentSize,
                anchor: anchorInScreen,
                screen: baseWindow?.screen ?? NSScreen.main
            )
        }

        // 2. 箭尖 = 锚点中心相对弹窗的偏移，钳制在气泡范围内（钳制后箭头跟随锚点）
        let half = PopoverBubbleShape.arrowHalfWidth
        let tip: CGFloat
        switch arrowSide {
        case .right:
            tip = min(max(anchorInScreen.midY - frame.minY, half + 2), contentSize.height - half - 2)
        case .top, .bottom:
            tip = min(max(anchorInScreen.midX - frame.minX, half + 2), contentSize.width - half - 2)
        }

        // 3. 用真实箭尖位置与测量一致的固定宽度构建最终内容并显示
        let hostingView = NSHostingView(
            rootView: content(PopoverLayoutInfo(arrowSide: arrowSide, tip: tip), fixedWidth)
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        // 主面板为 .statusBar 级别，弹窗需高一级才能完整可见
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.ignoresMouseEvents = true
        window.contentView = hostingView
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        self.window = window
    }

    func close() {
        window?.orderOut(nil)
        window = nil
    }

    /// 定位策略：优先弹窗在锚点左侧、垂直居中于锚点（箭头在右缘，主面板外侧显示）；
    /// 左侧空间不足时 fallback 垂直模式：悬停在锚点上方（箭头朝下），上方放不下翻转到锚点下方（箭头朝上）
    private static func layout(size: NSSize, anchor: NSRect, screen: NSScreen?) -> (frame: NSRect, arrowSide: PopoverBubbleShape.ArrowSide) {
        let margin: CGFloat = 4
        let gap: CGFloat = 6
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(origin: .zero, size: NSSize(width: 1920, height: 1080))

        // 左侧模式：右缘贴锚点左缘留 gap，垂直居中并钳制进屏幕可视区
        let leftX = anchor.minX - gap - size.width
        if leftX >= visible.minX + margin {
            var y = anchor.midY - size.height / 2
            y = max(visible.minY + margin, y)
            y = min(visible.maxY - margin - size.height, y)
            return (NSRect(x: leftX, y: y, width: size.width, height: size.height), .right)
        }

        // fallback 垂直模式（现有逻辑）
        var x = anchor.midX - size.width / 2
        x = max(visible.minX + margin, x)
        x = min(visible.maxX - margin - size.width, x)

        var arrowOnTop = false
        var y = anchor.maxY + gap
        if y + size.height > visible.maxY - margin {
            arrowOnTop = true
            y = anchor.minY - gap - size.height
        }
        return (NSRect(origin: NSPoint(x: x, y: y), size: size), arrowOnTop ? .top : .bottom)
    }
}

/// 弹窗整体形状：圆角气泡 + 指向三角（同一毛玻璃材质，无缝融合）
struct PopoverBubbleShape: Shape {
    /// 箭头位置
    enum ArrowSide {
        /// 箭头在底部（弹窗悬停在锚点上方，fallback 模式）
        case bottom
        /// 箭头在顶部（弹窗翻转到锚点下方，fallback 模式）
        case top
        /// 箭头在右缘指向锚点（弹窗位于锚点左侧、主面板外侧）
        case right
    }

    /// 箭头方向
    var side: ArrowSide = .bottom
    /// 箭尖在弹窗内的位置：top/bottom 为 x 坐标；right 为 y 坐标（已由 controller 钳制在气泡范围内）
    var tip: CGFloat = 0

    static let arrowHeight: CGFloat = 7
    static let arrowHalfWidth: CGFloat = 7

    func path(in rect: CGRect) -> Path {
        var path = Path()
        // 气泡矩形：箭头所在边缘向内收 arrowHeight，三角与气泡同材质融合
        let bubble: CGRect
        switch side {
        case .top:
            bubble = CGRect(x: rect.minX, y: rect.minY + Self.arrowHeight, width: rect.width, height: rect.height - Self.arrowHeight)
        case .bottom:
            bubble = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - Self.arrowHeight)
        case .right:
            bubble = CGRect(x: rect.minX, y: rect.minY, width: rect.width - Self.arrowHeight, height: rect.height)
        }
        path.addRoundedRect(in: bubble, cornerSize: CGSize(width: 8, height: 8), style: .continuous)

        // 指向三角：底边落在气泡靠近锚点的边缘，尖指向锚点方向
        // （SwiftUI shape 坐标系 y 向下；水平箭头基于气泡右缘向右伸出）
        switch side {
        case .top, .bottom:
            let arrowOnTop = side == .top
            let baseY = arrowOnTop ? bubble.minY : bubble.maxY
            let tipY = arrowOnTop ? rect.minY : rect.maxY
            path.move(to: CGPoint(x: tip - Self.arrowHalfWidth, y: baseY))
            path.addLine(to: CGPoint(x: tip, y: tipY))
            path.addLine(to: CGPoint(x: tip + Self.arrowHalfWidth, y: baseY))
        case .right:
            path.move(to: CGPoint(x: bubble.maxX, y: tip - Self.arrowHalfWidth))
            path.addLine(to: CGPoint(x: rect.maxX, y: tip))
            path.addLine(to: CGPoint(x: bubble.maxX, y: tip + Self.arrowHalfWidth))
        }
        path.closeSubpath()
        return path
    }
}

/// 弹窗布局结果：箭头方向 + 箭尖在弹窗内的位置（top/bottom 为 x 坐标，right 为 y 坐标）
struct PopoverLayoutInfo {
    let arrowSide: PopoverBubbleShape.ArrowSide
    let tip: CGFloat
}

/// 使用独立窗口承载 hover 弹窗，不被父视图裁剪；
/// placement: 放置在单个 cell 的 background 上，锚点为 cell 的精确 bounds
/// （positioningRect 来自 GeometryReader），由 CellPopoverWindowController 自管定位。
struct CellPopoverPresenter<Content: View>: NSViewRepresentable {
    let isPresented: Bool
    let positioningRect: CGRect
    /// 弹窗内容最大宽度（日历格子默认 220，列表条目详情可传更宽值）
    var maxWidth: CGFloat = 220
    let content: Content

    /// 弹窗外观：毛玻璃气泡（与提醒弹窗同款 .popover 材质）+ 圆角 + 描边 + 指向三角。
    /// 箭头区通过额外 padding 预留空间；描边只画气泡矩形（三角斜边不描，淡材质下不可见）。
    /// fixedWidth 非 nil 时内容按固定宽度布局（长文本换行，与测量保持一致）
    @ViewBuilder
    private func chromeContent(_ info: PopoverLayoutInfo, fixedWidth: CGFloat?) -> some View {
        Group {
            if let fixedWidth {
                content
                    .frame(width: fixedWidth, alignment: .leading)
            } else {
                content
                    .frame(maxWidth: maxWidth, alignment: .leading)
            }
        }
        .padding(10)
        .padding(.top, info.arrowSide == .top ? PopoverBubbleShape.arrowHeight : 0)
        .padding(.bottom, info.arrowSide == .bottom ? PopoverBubbleShape.arrowHeight : 0)
        .padding(.trailing, info.arrowSide == .right ? PopoverBubbleShape.arrowHeight : 0)
            .background(
                VisualEffectView(material: .popover, blendingMode: .behindWindow)
                    .clipShape(PopoverBubbleShape(side: info.arrowSide, tip: info.tip))
            )
            .clipShape(PopoverBubbleShape(side: info.arrowSide, tip: info.tip))
            .overlay(
                GeometryReader { geo in
                    // 描边矩形 = 气泡区域（右侧箭头时宽收 arrowHeight，上下箭头时高收 arrowHeight）
                    let bubbleWidth = info.arrowSide == .right
                        ? geo.size.width - PopoverBubbleShape.arrowHeight
                        : geo.size.width
                    let bubbleHeight = info.arrowSide == .right
                        ? geo.size.height
                        : geo.size.height - PopoverBubbleShape.arrowHeight
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                        .frame(width: bubbleWidth, height: bubbleHeight)
                        .position(
                            x: info.arrowSide == .right ? bubbleWidth / 2 : geo.size.width / 2,
                            y: info.arrowSide == .top
                                ? PopoverBubbleShape.arrowHeight + bubbleHeight / 2
                                : bubbleHeight / 2
                        )
                }
            )
    }

    func makeCoordinator() -> CellPopoverWindowController {
        CellPopoverWindowController()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if isPresented {
            if context.coordinator.isShowing { return }
            guard let window = nsView.window else { return }
            // 锚点格子：视图坐标系 → 窗口坐标系 → 屏幕坐标系
            let rectInWindow = nsView.convert(positioningRect, to: nil)
            let anchorInScreen = window.convertToScreen(rectInWindow)
            context.coordinator.show(
                content: chromeContent,
                anchorInScreen: anchorInScreen,
                baseWindow: window,
                maxContentWidth: maxWidth
            )
        } else {
            context.coordinator.close()
        }
    }
}

struct CalendarGridView: View {
    @Environment(AppSettings.self) private var appSettings
    @Binding var selectedDate: Date
    let calendarService: CalendarService
    let customSources: [CustomCalendarSource]
    let calendarPreferences: [CalendarPreference]

    @State private var currentMonth = Date()

    private let calendar = Calendar.current
    private let weekDaySymbols: [String] = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.veryShortWeekdaySymbols
    }()

    /// 根据 weekdayStart 设置排列的星期符号
    private var orderedWeekDaySymbols: [String] {
        let start = appSettings.weekdayStart // 1=Sunday, 2=Monday
        let index = start - 1
        return Array(weekDaySymbols[index...]) + Array(weekDaySymbols[..<index])
    }

    var body: some View {
        VStack(spacing: 0) {
            // 月份导航头
            CalendarHeaderView(
                currentMonth: $currentMonth,
                selectedDate: $selectedDate
            )

            Divider()

            // 星期标题行
            weekdayHeader

            Divider()

            // 日期网格
            dateGrid
                .padding(.top, 4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .tint(Color(hex: appSettings.accentColorHex))
    }

    // MARK: - Weekday Header

    private var weekdayHeader: some View {
        HStack(spacing: 2) {
            ForEach(orderedWeekDaySymbols.indices, id: \.self) { index in
                Text(orderedWeekDaySymbols[index])
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Date Grid

    private var dateGrid: some View {
        // V-9：@Query 下沉到子视图并以展示月为查询窗口（视图随 currentMonth 重建时
        // 谓词同步更新），避免全表加载后在 30+ 个日期格内重复过滤
        MonthEventGrid(
            month: currentMonth,
            selectedDate: $selectedDate,
            days: daysInMonth(),
            enabledCalendarIDs: Set(calendarPreferences.filter { $0.isEnabled }.map { $0.calendarID }),
            importantCalendarID: calendarPreferences.first { $0.isImportant }?.calendarID,
            hasImportantSource: customSources.contains { $0.isImportant && $0.isEnabled }
        )
    }

    // MARK: - Helpers

    private func daysInMonth() -> [Date] {
        guard let monthRange = calendar.range(of: .day, in: .month, for: currentMonth) else {
            return []
        }

        let firstDay = calendar.date(from: calendar.dateComponents([.year, .month], from: currentMonth))!
        let weekday = calendar.component(.weekday, from: firstDay)
        // 根据 weekdayStart 计算偏移：使星期列与 orderedWeekDaySymbols 对齐
        let start = appSettings.weekdayStart // 1=Sunday, 2=Monday
        let offset = (weekday - start + 7) % 7

        var days: [Date] = []

        // 填充上月末的日期
        if offset > 0 {
            for i in stride(from: offset, to: 0, by: -1) {
                if let date = calendar.date(byAdding: .day, value: -i, to: firstDay) {
                    days.append(date)
                }
            }
        }

        // 当月日期
        for day in monthRange {
            if let date = calendar.date(byAdding: .day, value: day - 1, to: firstDay) {
                days.append(date)
            }
        }

        // 填充下月初的日期，补全到完整行数
        let remainder = days.count % 7
        if remainder > 0 {
            let lastDay = days.last!
            for i in 1...(7 - remainder) {
                if let date = calendar.date(byAdding: .day, value: i, to: lastDay) {
                    days.append(date)
                }
            }
        }

        return days
    }
}

// MARK: - 月度事件网格（V-9：@Query 携带展示月窗口谓词）

/// 承载月视图日期网格与事件查询的子视图。
/// @Query 谓词在 init 中按 month 构建视图窗口（视图随 currentMonth 变化重建时谓词同步更新），
/// 避免父视图全表加载后在每个日期格内重复过滤。
private struct MonthEventGrid: View {
    @Environment(AppSettings.self) private var appSettings
    let month: Date
    @Binding var selectedDate: Date
    let days: [Date]
    let enabledCalendarIDs: Set<String>
    let importantCalendarID: String?
    let hasImportantSource: Bool

    @Query private var cachedEvents: [CachedEvent]

    private let calendar = Calendar.current

    init(month: Date, selectedDate: Binding<Date>, days: [Date], enabledCalendarIDs: Set<String>, importantCalendarID: String?, hasImportantSource: Bool) {
        self.month = month
        _selectedDate = selectedDate
        self.days = days
        self.enabledCalendarIDs = enabledCalendarIDs
        self.importantCalendarID = importantCalendarID
        self.hasImportantSource = hasImportantSource

        // 查询窗口覆盖 days 数组全部范围：当月 1 日前扩 7 天、后扩 38 天
        //（最长 31 天月 + 7 天尾部补位），保证上月末/下月初格子的跨天事件可见
        let firstDay = calendar.date(from: calendar.dateComponents([.year, .month], from: month))!
        let windowStart = calendar.date(byAdding: .day, value: -7, to: firstDay)!
        let windowEnd = calendar.date(byAdding: .day, value: 38, to: firstDay)!
        // 哨兵日期用局部常量捕获：#Predicate 宏内不支持隐式成员访问（.distantPast），
        // 会展开成静态成员 keypath 导致类型推断失败
        let distantPast = Date.distantPast
        let distantFuture = Date.distantFuture
        // Query 初始化器参数标签是 filter/sort（predicate 是 FetchDescriptor 的标签）
        let predicate = #Predicate<CachedEvent> { event in
            (event.startDate ?? distantPast) < windowEnd
                && (event.endDate ?? distantFuture) > windowStart
        }
        _cachedEvents = Query(
            filter: predicate,
            sort: [SortDescriptor(\.startDate)]
        )
    }

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
        let events = cachedEvents

        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(days, id: \.self) { date in
                let dayEvents = eventsForDay(date, from: events)
                let isImportant = isDayImportant(date, dayEvents: dayEvents)

                CalendarDayCell(
                    date: date,
                    isSelected: calendar.isDate(date, inSameDayAs: selectedDate),
                    isToday: calendar.isDateInToday(date),
                    isCurrentMonth: calendar.isDate(date, equalTo: month, toGranularity: .month),
                    lunarText: LunarCalendarHelper.lunarString(for: date),
                    eventItems: dayEvents.map { CalendarEventItem(title: $0.title, colorHex: $0.eventColorHex ?? $0.calendarColorHex, category: $0.category.rawValue, timeText: Self.popoverTimeText(for: $0)) },
                    systemCalendarColor: Color(hex: appSettings.systemCalendarColorHex),
                    subscriptionCalendarColor: Color(hex: appSettings.subscriptionCalendarColorHex),
                    isImportant: isImportant
                )
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selectedDate = date
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private static let popoverTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// hover 弹窗事件行时间文本：全天显示"全天"，定时事件显示开始时间，无开始时间返回 nil
    private static func popoverTimeText(for event: CachedEvent) -> String? {
        if event.isAllDay { return "全天" }
        guard let start = event.startDate else { return nil }
        return popoverTimeFormatter.string(from: start)
    }

    /// 从 CachedEvent 列表中筛选指定日期的事件
    private func eventsForDay(_ date: Date, from events: [CachedEvent]) -> [CachedEvent] {
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        return events.filter { event in
            guard let start = event.startDate, let end = event.endDate else { return false }
            guard start < endOfDay && end > startOfDay else { return false }
            if event.category == .system {
                return enabledCalendarIDs.isEmpty || enabledCalendarIDs.contains(event.calendarID)
            }
            return true
        }
    }

    /// 判断指定日期是否为重要日期
    private func isDayImportant(_ date: Date, dayEvents: [CachedEvent]) -> Bool {
        guard importantCalendarID != nil || hasImportantSource else { return false }
        if let calID = importantCalendarID {
            if dayEvents.contains(where: { $0.category == .system && $0.calendarID == calID }) {
                return true
            }
        }
        if hasImportantSource {
            if dayEvents.contains(where: { $0.category == .subscription }) {
                return true
            }
        }
        return false
    }
}
