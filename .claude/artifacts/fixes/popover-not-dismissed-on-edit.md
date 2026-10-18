# Fix: popover-not-dismissed-on-edit

> Status: FIXED（待用户验收）
> Date: 2026-10-18
> Mode: --quick（单点修复）

## Triage

- **Symptom**：点击行上"修改事项"按钮后，hover 详情弹窗不消失，悬浮在编辑窗口之上
- **Expected**：打开编辑窗口时弹窗收起
- **Repro**：hover 待办条目 → 弹窗出现 → 点击行内铅笔（修改）按钮 → 编辑窗口打开，弹窗仍悬浮
- **Severity**：影响功能（弹窗遮挡编辑窗口）

## Root cause

弹窗由 `EventItemRow` 的 `isPresented: isHovered` 驱动。点击编辑按钮时鼠标物理上仍悬停在行内，`onHover` 只在进入/离开时触发，不会发出 false → `isHovered` 保持 true → 弹窗不关；弹窗窗口 level（statusBar+1）高于编辑窗口，遮挡在最上层。与 EditEventWindowManager 无关（行位移检测也不触发，主面板未移动）。

## Fix

[EventItemRow.swift](file:///Users/thking/code/codeBuddy/SwallowCalendar/SwallowCalendar/Views/Events/EventItemRow.swift#L126-L131) 编辑按钮 action 首行加 `isHovered = false`：SwiftUI 状态显式收起弹窗（updateNSView close）。鼠标不动时 onHover 不会重新触发，弹窗保持关闭；移出再移入正常弹出。行内操作按钮同时收起（isHovered 驱动），状态自洽。

## Verify

- swift build exit 0（0.14s）；部署 /Applications 重签运行（pid 22493）
- 手动验证（待用户）：hover → 点修改 → 弹窗立即消失，编辑窗口无遮挡；关闭编辑窗口后鼠标移出行再移入，弹窗正常重现
