# edit-panel-ui Spec

> Status: ALIGNED
> Author: user
> Last updated: 2026-10-18

## Background
编辑事项窗口（EditEventSheet，EditEventWindowManager 独立窗口承载）UI 为功能堆叠：表单行无分组、Toggle/DatePicker 原生风格与自定义行不统一、颜色选中态弱、固定 350×450 内容不满时空白大、无键盘快捷键。用户确认优化为**原生分组卡片风**（同系统日历/提醒事项编辑面板）。

## In scope
- EditEventSheet body 重构：分组卡片布局（基本信息 / 属性两组）、行统一左标签右控件、颜色选中环、顶部日历色点上下文、保存/取消键盘快捷键
- 窗口尺寸：宽度固定 340、高度随内容自适应（EditEventWindowManager 用 fittingSize）
- 保存逻辑（saveEvent）不动

## Out of scope
- EditEventWindowManager 打开机制（单窗口复用）不变
- 字段增删、校验规则不变

## Assumptions
- 卡片底色用系统语义色（windowBackground / controlBackground），跟随深浅色模式，不做毛玻璃

## Solution
1. 私有组件 FormCard（section 标题 + 圆角卡片容器）、FormRow（左 label 右控件）
2. 布局：顶部标题行（日历色点 + "修改事件" + 取消[Esc]）→ 卡片"基本信息"（标题输入 / 全天开关 / 日期时间）→ 卡片"属性"（颜色 / 优先级 / 周期 / 提醒）→ 全宽保存[Cmd+Return]
3. 颜色圆点选中态：外圈描边环 + 未选中无描边；Button(.plain) 替代 onTapGesture
4. EditEventWindowManager：NSHostingView(rootView: editView) fittingSize 定窗口高

## Edge cases & risks
| Category | Notes |
|---|---|
| 高度自适应 | fittingSize 需固定宽度后再测，否则宽度不确定 |
| 深色模式 | 全部用系统语义色，不自定硬编码色 |
| 快捷键冲突 | Esc cancelAction / Cmd+Return defaultAction，无系统冲突 |

## Acceptance criteria
- AC-1: 打开编辑窗口 → 分组卡片布局，两组 section 清晰分隔，行左标签右控件对齐
- AC-2: 深浅色模式下卡片与窗口背景均有层次对比
- AC-3: 颜色圆点选中可见（外环），可再次点击取消
- AC-4: Esc 取消、Cmd+Return 保存生效；保存行为与重构前完全一致
- AC-5: 窗口高度随内容自适应，无大片空白
