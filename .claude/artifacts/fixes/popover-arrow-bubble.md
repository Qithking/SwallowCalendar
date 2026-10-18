# Bug: hover 弹窗三角箭头穿越气泡，位置与形状全错

> Status: FIXED
> Mode: (default)
> Severity: minor
> Author: user
> Last updated: 2026-10-18

## Symptom

popover-arrow-style 实现后首次部署，弹窗三角箭头"位置和其他都不对"：
三角底边落在气泡远端边缘、尖在另一端，形成横跨整个弹窗的穿越三角，
气泡被斜线切割破坏。

## Expected

三角底边紧贴气泡靠近锚点格子的边缘，尖指向格子；
arrowOnTop=false（弹窗悬停格子上方）时箭头在弹窗底部尖朝下，
arrowOnTop=true（翻转）时箭头在弹窗顶部尖朝上。

## Reproduction

- 步骤：hover 任意有事件的格子（必现）
- 复现稳定性：100%（几何确定性 bug，代码审查即可复现；
  项目无测试 target，UI 几何 bug 沿用 pop-offset 先例：静态几何证明 + 用户视觉验收）

## Hypotheses & diagnosis

| # | Hypothesis | Verdict | Evidence |
|---|---|---|---|
| H1 | PopoverBubbleShape 的 baseY/tipY 在 SwiftUI shape 坐标系（y 向下 flipped）下映射反了 | **confirmed (root cause)** | 坐标推演：arrowOnTop=false 时 bubble 占顶部 [minY, height-7]，代码取 baseY=bubble.minY（气泡顶边）+ tipY=rect.maxY → 三角从顶部横跨到底部；正确应为 baseY=bubble.maxY（气泡底边） |
| H2 | tipX 计算错误 | eliminated | 代码审查：AppKit 屏幕 x 与 SwiftUI x 同向，`anchor.midX - frame.minX` 偏移正确且钳制在弹窗内 |
| H3 | chrome padding 与 shape 高度不匹配 | eliminated | top/bottom padding = arrowHeight 与 bubble 高度扣除（rect.height - arrowHeight）一致，测量（fittingSize）与布局同一套几何 |

## Root cause

SwiftUI `Shape.path(in:)` 的 rect 使用 y 向下的 flipped 坐标系，而三角底边 y 的
条件映射写反：`baseY = arrowOnTop ? bubble.maxY : bubble.minY`（恰好相反）。
导致三角底边始终落在气泡**远离锚点**的边缘、尖在视图另一端，
路径为横跨整个弹窗的穿越三角，fill 融合后气泡整体形状被破坏。

## Fix

- 改动文件：`SwallowCalendar/Views/Calendar/CalendarGridView.swift:118`（1 行）
- `baseY = arrowOnTop ? bubble.maxY : bubble.minY` →
  `baseY = arrowOnTop ? bubble.minY : bubble.maxY`
  （tipY 原本正确，未动；补注释说明 flipped 坐标系方向语义）

## Verification

- V-1: 坐标推演复查：arrowOnTop=false → baseY=bubble.maxY（气泡底边）+ tipY=rect.maxY（视图底部），
  三角紧贴气泡下边缘尖朝下 ✓；arrowOnTop=true → baseY=bubble.minY + tipY=rect.minY，尖朝上 ✓
- V-2: `swift build -c debug` → Build complete, exit 0（增量 0.15s，
  二进制 mtime 09:06:38 晚于源文件 09:06:21，确认修复入包）
- V-3: 部署链路：quit → Finder Apple Events 替换 → codesign 重签 →
  运行中（pid 14249）；AC-1/2/6 视觉验收待用户确认

## Regression test

- 不适用（项目无测试 target；AC-1/2/6 手动视觉验收见 .work/待办计划.md）

## Pattern analysis

| 搜索方式 | 命中数 | 是否本次同类隐患 |
|---|---|---|
| `grep -n "rect.maxY\|rect.minY" SwallowCalendar/Views/Calendar/CalendarGridView.swift` | 4（均在 PopoverBubbleShape 内） | 否，修复后语义一致 |
| `grep -rn "flipped\|y 向下" SwallowCalendar/` | 仅本次新注释 | 否 |

结论：仓库内无其他手写 Shape path 的 y 向映射逻辑，无同类隐患。

## Open questions / Follow-ups

- 三角根部与气泡描边（strokeBorder 只描气泡矩形）的 1pt 交线在 0.12 透明度下
  预期不可见——若用户视觉验收发现接缝线明显，单独处理描边开口（未确认不预改）
