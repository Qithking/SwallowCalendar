# event-row-detail-popover Spec

> Status: ALIGNED
> Author: user
> Last updated: 2026-10-18

## Background
日历格子已有 hover 弹窗（`CellPopoverWindowController` + `PopoverBubbleShape` + `CellPopoverPresenter`，见 CalendarGridView.swift）。待办事项与已办事项列表条目（共用 `EventItemRow`）目前 hover 只显示编辑/删除按钮，缺少详细信息展示。为两列表条目添加同款 hover 详情弹窗。

## In scope
- `EventItemRow` 增加 hover 弹窗（待办/已办两列表同时生效）
- 复用 `CellPopoverPresenter` / `CellPopoverWindowController` / `PopoverBubbleShape`（三角指向、屏幕钳制、翻转定位全部继承）
- 弹窗为完整信息：完整标题、起止/截止时间、优先级、日历来源（色点+名称）、周期类型、系统提醒标签、完成状态（已完成时）
- 触发方式：hover 悬停显示，移开关闭；弹窗点击穿透（沿用 `ignoresMouseEvents`）

## Out of scope
- 弹窗内不放操作按钮（编辑/删除/完成仍走行内 hover 按钮）
- 日历格子弹窗行为不变
- 列表排序/过滤/刷新逻辑不变

## Assumptions
- 弹窗锚点为整行 bounds，箭头指向行
- 行内已展示的信息（倒计时、过期标记）不在弹窗内重复；完成状态仅在已完成时显示"已完成"
- 列表滚动/窗口移动导致行位置变化时关闭弹窗（避免锚点陈旧）

## Solution
1. `CellPopoverPresenter` 参数化 `maxWidth`（默认 220，日历格子调用不变；列表条目传更宽值容纳完整信息）
2. `EventItemRow` 的 background 加 GeometryReader + `CellPopoverPresenter`（isPresented: isHovered）；GeometryReader 检测全局 frame 变化（滚动/窗口移动）时置 `isHovered = false` 关闭弹窗
3. 新增 `EventRowPopoverContent`（内聚在 EventItemRow.swift）：标题 + 信息行（时间/优先级/重复/日历来源）+ 提醒标签 + 已完成标记
4. 文案复用现有枚举：`EventPriority.displayName`、`RecurrenceType.rawValue`

## Edge cases & risks
| Category | Notes |
|---|---|
| 滚动锚点陈旧 | GeometryReader frame 变化 → 关闭；不重开直到重新 hover |
| 行 hover 双用途 | 弹窗点击穿透，不挡行内操作按钮；操作按钮 hover 时弹窗仍在（信息无害） |
| 首次布局 | onChange(of: frame) 首次触发时 isHovered=false，无误关 |
| 无到期时间 | 时间行显示"无到期时间" |

## Acceptance criteria
- AC-1 hover 待办列表条目 → 弹窗带三角箭头指向该行，展示完整标题/时间/优先级/日历来源/周期/提醒标签
- AC-2 hover 已办列表条目 → 同样弹窗，且含"已完成"状态
- AC-3 鼠标移开条目 → 弹窗消失
- AC-4 屏幕右缘/顶部边缘时定位与日历格子弹窗一致（钳制 + 翻转）
- AC-5 列表滚动时弹窗关闭
- AC-6 弹窗点击穿透：行内编辑/删除按钮、完成复选框可正常点击
- AC-7 日历格子弹窗行为与之前完全一致（maxWidth 默认值回归）
