# Fix: popover-content-truncated

> Status: FIXED（待用户验收）
> Date: 2026-10-18
> Mode: --quick（单文件根因明确）

## Triage

- **Symptom**：待办/已办弹窗内容超出部分全部被省略（"弹出待办事项内容必须全部显示"需求去掉 lineLimit 后仍截断）
- **Expected**：长标题/长字段换行完整显示，无省略号
- **Repro**：hover 含长标题的待办条目 → 弹窗标题被截断省略
- **First seen**：event-row-detail-popover 去除 lineLimit 之后（pid 19142 版本）
- **Severity**：影响功能（详情不可读）

## Root cause

`CellPopoverWindowController.show` 用 `NSHostingView.fittingSize`（SwiftUI **理想尺寸**）决定窗口高度。理想尺寸对长文本按"最宽单行"计；内容经 chrome 的 `.frame(maxWidth:)` 钳宽后，渲染时需要按换行计算更多高度，但窗口已被钉在理想（过矮）高度 → 渲染提案高度不足 → SwiftUI Text 尾部省略。

关键点：测量提案（unspecified → 单行理想）与渲染提案（固定窗口尺寸 → 换行）不一致。有 lineLimit 时代同理存在（长标题单行内截断），用户上轮要求全显示后问题显性化。

## Fix

两步测量，使测量与渲染提案一致（CalendarGridView.swift）：

1. `show` 增加参数：content 闭包签名 `(PopoverLayoutInfo, CGFloat?) -> some View`（第二参为内容固定宽度），新增 `maxContentWidth`
2. 测量：先无约束测理想尺寸；宽度超出 `maxContentWidth` 时以固定宽度（= maxContentWidth）重测，得到换行后的完整高度
3. 最终视图用与测量一致的 fixedWidth 构建；`chromeContent` 按 fixedWidth 分支：非 nil 用 `.frame(width:)`，nil 保持原 `.frame(maxWidth:)`（自适应行为不变）
4. `updateNSView` 传 `maxContentWidth: maxWidth`（日历格子 220 / 列表条目 260）

## Defense-in-depth

无（--quick，根因单一；自适应路径未动，无回归面）。

## Verify

- swift build exit 0（增量 0.14s）；部署 /Applications 重签运行（pid 20212）
- 手动验证（待用户）：hover 长标题待办/已办条目 → 内容换行完整显示无省略号；短内容弹窗宽度仍自适应
