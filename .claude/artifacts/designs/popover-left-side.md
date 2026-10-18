# popover-left-side Spec

> Status: ALIGNED
> Author: user
> Last updated: 2026-10-18

## Background
现弹窗（日历格子 + 待办/已办列表条目）悬停在锚点上/下方，覆盖面板内容。用户要求弹窗显示在主面板外面、锚点左侧。经确认**两种弹窗都改**（日历格子 + 列表条目）。

## In scope
- `CellPopoverWindowController` 定位策略改为：优先弹窗在锚点左侧、垂直居中（箭头在弹窗右缘指向锚点）；左侧空间不足时 fallback 到现有垂直布局（上/下翻转）
- `PopoverBubbleShape` 扩展右缘箭头模式（`.right`），保留上/下箭头（fallback 用）
- `CellPopoverPresenter` chrome 按 arrowSide 适配 padding 与描边
- 日历格子与列表条目两个调用点自动生效（无需改动调用侧）

## Out of scope
- 弹窗内容（EventRowPopoverContent / 格子内容）不变
- 触发方式不变（hover）
- 点击穿透不变

## Assumptions
- "应用外面" = 弹窗主体位于主面板窗口边界之外（左侧），弹窗右缘贴锚点左缘留 gap
- 垂直方向弹窗居中于锚点，超出屏幕可视区上下钳制，箭尖跟随锚点中心（钳制后仍在气泡内）

## Solution
1. `PopoverBubbleShape.ArrowSide` 枚举：`.top` / `.bottom`（现有）/ `.right`（新增）；`tipX/arrowOnTop` 合并为 `side + tip`（tip 语义：top/bottom 为 x 坐标，right 为 y 坐标）
2. `PopoverLayoutInfo`（arrowSide + tip）贯穿 controller → presenter chrome 闭包
3. layout：`leftX = anchor.minX - gap - width`，若 `leftX >= visible.minX + margin` 走左侧模式（垂直居中 + 上下钳制 + tip=锚点中心 y 偏移）；否则 fallback 现有垂直逻辑；fallback 时按 `.bottom` 占位重测尺寸
4. chromeContent：`.right` 时内容加 `padding(.trailing, arrowHeight)`，描边矩形宽度减 arrowHeight 居左

## Edge cases & risks
| Category | Notes |
|---|---|
| 左侧空间不足 | 面板贴屏幕左缘时 fallback 垂直模式（现有行为） |
| 垂直钳制 | 弹窗高于可视区时上下钳制，箭尖钳制在气泡内 |
| 占位测量 | .right 与垂直模式 padding 方向不同，fallback 时重测 |
| 描边接缝 | .right 模式描边只画气泡矩形（同现有做法，三角斜边不描） |

## Acceptance criteria
- AC-1: hover 日历格子 → 弹窗出现在面板外面、格子左侧，箭头从弹窗右缘指向该格子
- AC-2: hover 待办/已办条目 → 同样左侧弹窗，箭头指向该条目
- AC-3: 弹窗垂直居中于锚点；锚点靠屏幕上/下缘时弹窗钳制进屏幕且箭头仍指锚点
- AC-4: hover 离开关闭、点击穿透、内容排版均不变
- AC-5: 面板被拖到屏幕左缘附近时弹窗不溢出屏幕（fallback 垂直模式）
