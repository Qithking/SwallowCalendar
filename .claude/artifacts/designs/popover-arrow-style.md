# popover-arrow-style Spec

> Status: IMPLEMENTED（待用户视觉验证）
> Author: user
> Last updated: 2026-10-18

## Background

hover 弹窗（pop-offset 第二轮产物：CellPopoverWindowController 自管窗口）定位已正确，
但缺少指向锚点格子的三角箭头（v1 设计取舍），且内容排版朴素观感不佳。
本次对齐 macOS 系统日历 App 的 hover 预览范式补齐这两点。

## In scope

- 弹窗增加三角指向箭头（毛玻璃同材质 + 同描边），指向锚点格子
- 贴边钳制时箭头跟随锚点：弹窗右对齐后箭头仍位于锚点 x 位置，且不出弹窗边界
- 垂直翻转（弹窗在格子下方）时箭头位于弹窗底部
- 内容排版对齐系统日历：日期标题 + 事件行（事件色圆点 + 时间文本 + 标题）
- 视觉细节：毛玻璃、圆角、描边、间距、字号层次

## Out of scope

- 定位算法本身（水平居中 → 钳制 → 翻转策略已修复，不改动）
- 提醒弹窗 ReminderAlertView 的样式
- 事件点击交互（弹窗保持点击穿透）
- 无箭头方案回退开关

## Assumptions

- 时间文本：定时事件显示开始时间（如 14:30），全天事件显示"全天"
- 箭头尺寸约 10-12pt 宽，视觉习惯值
- 箭头与气泡在同一窗口内容内（一体绘制），非独立窗口

## Solution

改动集中在 CalendarGridView.swift（CellPopoverPresenter chrome + CellPopoverWindowController
frame 计算）与 CalendarDayCell.swift（popoverContent 事件行排版）：

1. **箭头**：窗口内容 = 箭头三角形 + 气泡圆角矩形两部分。自定义 Shape 绘制箭头，
   材质/描边与气泡一致；箭头绘制在气泡边缘上层覆盖描边交线。
2. **箭头定位**：frame 计算返回弹窗 x 的同时计算箭头在弹窗内的相对 x
   （锚点 midX − 弹窗 minX，钳制到 [margin+arrowHalf, width−margin−arrowHalf]），
   通过参数传入内容视图。
3. **事件行**：HStack = 事件色圆点(6pt) + 时间文本（次要色、11pt、单行）+ 标题
   （11pt、lineLimit 2）。

## Edge cases & risks

| Category | Notes |
|---|---|
| Boundary conditions | 第 7 列贴右缘：弹窗右对齐，箭头 x 钳制在弹窗内右侧区域且仍指格子 |
| Failure modes | 无 |
| Risks | 毛玻璃箭头与气泡描边交线可见（接缝痕迹） |
| Mitigation | 箭头绘制在气泡边缘上层覆盖交线；描边走向按开口边处理 |

## Acceptance criteria

- AC-1: hover 任意有事件格子 → 弹窗出现且三角箭头指向该格子
- AC-2: hover 第 6/7 列格子 → 弹窗钳制进屏幕，箭头仍指 hover 格子且不出弹窗边界
- AC-3: 内容排版为日期标题 + 事件行（色点 + 时间 + 标题），层次分明
- AC-4: 全天事件显示"全天"，定时事件显示开始时间
- AC-5: hover 离开 → 弹窗关闭；点击穿透主面板正常
- AC-6: 顶部行格子上方空间不足 → 弹窗翻转到格子下方，箭头位于弹窗底部且指向格子

## Interview metadata

- Mode: --quick
- Waves: 1
- Final ambiguity: ~15%
- Status: PASSED
