# 性能: 日历 hover 弹出预览资源占用较高

> Status: FIXED
> Mode: (default)
> Severity: performance
> Author: user
> Last updated: 2026-10-17

## Triage

- **Symptom**: 鼠标在日历日期间移动、hover 弹出事件预览（popover）期间 CPU 占用偏高
- **Expected**: hover 仅产生单元格级的最小渲染开销
- **Environment**: macOS 27.0.1 / Xcode 27.1 / SwiftUI 42 格月历网格（6 行 × 7 列）+ NSPopover 预览
- **Severity**: performance

## Root cause（两条 confirmed，一条 eliminated）

### H1（confirmed）：hover 状态提升在父视图

- `CalendarGridView` 持有 `@State hoveredDate: Date?`，`.onHover` 挂在每个单元格上
- 任一格进/出 hover → 父视图 state 变化 → 父 body 重算 → **42 格 CalendarDayCell 全部重建**
- 鼠标划过 k 格触发 **2k+1 次全网格重算**（每格 enter + leave 各一次）

### H2（confirmed，量化）：DateFormatter 每次重算全量新建

- 全网格重算时每格调 `LunarCalendarHelper` 计算农历文案，`lunarDay`/`lunarMonth`/`heavenlyStemAndEarthlyBranch` 每次调用新建 1-2 个 `DateFormatter`
- 单次全网格重算 ≈ 84 个 DateFormatter 新建 = **7.1ms**（对比静态缓存复用 **0.14ms**，约 51×）
- DateFormatter 构造成本 ≈ `string(from:)` 的 50 倍

### H3（eliminated）：popover 内容 churn

- 弹出仅在 hover 停留时创建一次，非滑动热路径，贡献次要

## Fix（3 文件，外科手术式）

1. **CalendarDayCell.swift**
   - hover 状态下沉：删除 `let isHovered` 入参，改为本地 `@State private var isHovered`
   - popover 内聚：`CellPopoverPresenter` + `popoverContent`/`popoverItemColor` 移入本文件，仅 `isHovered && !eventItems.isEmpty` 时弹出
   - 新增静态 `popoverDateFormatter`（"M月d日"）
2. **CalendarGridView.swift**：删除父级 `hoveredDate`、`isHovering` 计算及 popover 相关辅助代码
3. **LunarCalendarHelper.swift**：新增 3 个 static 缓存 formatter（"d" / "M月" / "UU年"），附中文注释说明缓存原因（网格每次重算调用 40+ 次）

效果：hover 进出仅重渲染该格自身；农历字符串不再新建 formatter

## Verification

- V-1: `swift build`（Xcode 27.1）→ **Build complete, exit 0**
- V-2: 未修改文件（如 AppSettings.swift）在环境故障期同样报错，代码修改与故障无关的判别依据
- 手动验证（待执行，见 .work/待办计划.md）：滑过日历观察 CPU 下降；hover 弹窗行为回归（有事件格子弹出、无事件不弹、内容正确）

### 构建环境插曲（诊断记录）

- Trae 沙箱间歇性阻止 swift-plugin-server 进程 → 全部宏展开失败（malformed response）+ 级联假错误（@State 失败 → "self is immutable" 等）
- 诊断链：HOME 重定向 ✗ → pkill ✗ → 清理 .build/out 全量重建 ✗ → 单独验证 plugin server / 宏 dylib / `-load-resolved-plugin` 语法均正常 → **重放失败文件的完整 swift-frontend 命令成功后，swift build 即恢复正常**
- 判别技巧：未修改文件同报宏错误 = 环境问题而非代码问题；与执行文档 2026-10-17 "真相修正"结论一致（沙箱是根因，用户环境正常）

## Pattern analysis

全仓 `DateFormatter()` 新建扫描（17 处）：

| 分类 | 位置 | 处理 |
|---|---|---|
| 已是 static 缓存 | EventItemRow ×2、ReminderAlertView ×1、DataExportSettingsView ×4、CalendarGridView weekDaySymbols ×1 | 无需处理 |
| 本次新增缓存 | LunarCalendarHelper ×3、CalendarDayCell popoverDateFormatter ×1 | 本次修复 |
| 函数内新建（低频路径，非热点） | ICSService:129（ICS 解析）、StatusBarIconManager:136/215（菜单栏图标）、CalendarHeaderView:81（monthTitle）、GeneralSettingsView:121（预览） | 未改动（surgical） |

## Open questions / Follow-ups

- 低频路径的 DateFormatter 新建如后续出现热点化，可统一收敛为共享缓存（非必须）
- `.work/待办计划.md` 中的手动验证项：hover CPU 对比、弹窗行为回归
