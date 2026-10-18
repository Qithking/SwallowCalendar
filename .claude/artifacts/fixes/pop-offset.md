# Bug: hover 弹窗定位偏移（日历右侧日期）

> Status: FIXED（第二轮：自定义窗口弹窗，彻底消除系统 reposition）
> Mode: dev-fix
> Severity: minor
> Author: user
> Last updated: 2026-10-18

## Triage

- **Symptom**: hover 日历右侧部分日期时，事件预览弹窗（NSPopover）整体向左偏移一格以上
- **Pattern**: 日历左边的日期正常，右边部分日期不正常；每次必现
- **用户确认的关键观察**: 弹窗整体偏左但**箭头仍指着 hover 的格子**
- **Environment**: 主面板为 NSPanel（右上角贴屏幕右缘 ~10pt），42 格月历 + NSPopover 预览

## Hypotheses

| # | 假设 | 结论 |
|---|---|---|
| H1 | positioningRect 坐标换算错误（cell 内 GeometryReader 挂载点变化导致） | eliminated：插桩坐标链日志证明锚点 100% 正确 |
| H2 | NSPanel 坐标系（convertToScreen）偏移 | eliminated：screenRect 精确落在 hover 格子上 |
| H3 | NSPopover 屏幕右缘空间不足时的系统级 reposition | **confirmed** |

## Root cause（H3 confirmed）

**NSPopover 系统级 reposition 行为，非代码坐标 bug。**

### 证据 1：插桩坐标链全部正确

在 `CellPopoverPresenter.updateNSView` 的 `show` 前插桩（notice 级），记录
`positioningRect → rectInWindow → screenRect → winFrame` 全链路：

- day=4 → 第1行第7列、day=10 → 第2行第6列、day=17/18 → 第3行第6/7列
- 行高 40 / 列宽 44.57（LazyVGrid 7 列 flexible spacing 2、面板 padding 8：(324-12)/7）全部吻合
- 每次屏幕坐标都精确对准 hover 格子 → 锚点计算无缺陷

### 证据 2：第 6/7 列几何上必然溢出

- 面板 winFrame=(2210, 767, 340, 642)，右缘 x=2550；屏幕右缘 ≈2560
- 第 7 列格子中心 x≈2519.75，距屏幕右缘仅 **~40pt**
- popover 内容宽 ≥140（minWidth 140 + 内容自适应），居中放置需向右伸 ~70pt
  → 右缘 2589.75，**超出屏幕 ~30pt** → 系统强制 reposition
- 第 6 列（中心 ≈2473.3）在内容较宽时同样溢出 → 解释"右边**部分**日期"不正常（取决于当天事件内容宽度）

### 证据 3：用户确认的表现 = reposition 标准行为

空间不足时系统把弹窗整体平移到锚点左侧塞进屏幕，**箭头仍指向锚点格子**——
与 macOS 系统日历 App 在屏幕右缘的表现一致。左侧列空间充足则正常居中。

## Fix

### 第一轮（2026-10-17）：接受系统行为，零代码改动

用户决策接受 macOS 标准 NSPopover 表现，仅移除 `[bug-popoffset]` 插桩日志
（CalendarGridView.swift `updateNSView`、CalendarDayCell.swift `.onHover`）。

### 第二轮（2026-10-18）：用户反馈观感不可接受，实施自定义窗口弹窗

用户重新反馈"还是一样的问题"，确认要真正消除偏移，决策采用**自定义窗口弹窗**
（仿 ReminderAlertWindow 模式）。改动集中于 [CalendarGridView.swift](file:///Users/thking/code/codeBuddy/SwallowCalendar/SwallowCalendar/Views/Calendar/CalendarGridView.swift)：

1. **删除** `PopoverCoordinator`（NSObject + NSPopoverDelegate）与 NSPopover 逻辑
2. **新增** `CellPopoverWindowController`：自管 borderless NSWindow 承载弹窗
   - `NSHostingView` + `fittingSize` 自适应内容尺寸
   - `isOpaque = false`、`backgroundColor = .clear`、`hasShadow = true`
   - 窗口级别 `.statusBar + 1`（主面板为 `.statusBar` 级 NSPanel，需高一级才能完整可见）
   - `ignoresMouseEvents = true`：点击穿透回主面板，hover 离开自然驱动关闭（等效 transient）
3. **重写** `CellPopoverPresenter`（NSViewRepresentable）：
   - 定位策略（静态 `frame(size:anchor:screen:)`）：
     - 水平：优先居中于锚点格子 → 超出 `visibleFrame` 时钳制进屏幕
       （贴右缘时等效右对齐，**这正是修复点**：不再被系统整体左移、箭头与弹窗脱节）
     - 垂直：悬停在格子上方（gap 6pt），上方放不下翻转到格子下方
   - 锚点换算：cell 内 `positioningRect` → 窗口坐标 → `convertToScreen` 屏幕坐标
   - 外观 chrome：`VisualEffectView(material: .popover)` 毛玻璃 + 圆角 8 +
     `strokeBorder(primary, 0.12)` 描边，与提醒弹窗视觉一致；`maxWidth: 220`

**设计取舍**：v1 不画指向箭头（材质匹配三角形的 hack 风险高）——hover 格子本身有
主题色边框高亮，足以指示锚点。

## Verification

- V-1: `grep -rn "bug-popoffset"` → **0 匹配**（第一轮）
- V-2: `swift build -c debug` → **Build complete, exit 0**（第二轮，17.83s 全量重建；
  期间构建缓存损坏触发宏插件 malformed response，`swift package reset` 后恢复）
- V-3: 部署链路：quit 应用 → Finder Apple Events 替换二进制 →
  `codesign --force --deep -s -` 重签 → 应用已启动（pid 8304）
- V-4（待用户确认）: 右侧列（第 6/7 列）hover 弹窗不再偏移；左列正常；
  毛玻璃外观可接受；hover 离开正常关闭

## Pattern analysis

- NSPopover 的自动 reposition 是设计行为：箭头指示锚点、弹窗体钳制进屏幕。
  任何使用 NSPopover 的应用在屏幕边缘都如此表现；无法通过代码关闭该行为。
- **自管 borderless 窗口是唯一能完全控制边缘定位的方案**：定位算法自己写
  （居中优先 → 钳制 → 翻转），代价是失去系统箭头与自动 transient 语义
  （此处用 `ignoresMouseEvents` + hover 离开关闭等效还原）。
- 教训：屏幕边缘组件的"错位"先量几何（锚点 vs 屏幕 vs 内容宽度），再下坐标 bug 结论；
  若系统组件行为不可接受，替代组件比对抗系统行为更省力。
- 环境教训：`swift build` 报宏插件 "malformed response" 且持续复现时，
  `swift package reset` 全量重建即可恢复（进程 kill/等待均无效）。

## Open questions / Follow-ups

- ~~/Applications 插桩版二进制决策项~~：已随第二轮修复部署被替换，不再存在
