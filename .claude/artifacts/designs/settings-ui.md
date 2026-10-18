# settings-ui Spec

> Status: ALIGNED
> Author: user
> Last updated: 2026-10-18

## Background
设置界面（TabView 四 tab：通用/同步/数据/关于）已是 .formStyle(.grouped) 原生分组风，但细节粗糙：主题色选中态弱、日历行 toggle 用 scaleEffect(0.7) hack、权限提示 10pt 过小、订阅添加行拥挤、各 tab 字号/间距不统一。用户确认**整体细节打磨**（不改结构）。

## In scope
- GeneralSettingsView：主题色圆点选中环（对齐编辑面板质感）、自定义格式区排版
- CalendarSettingsView：权限提示字号层级、toggle 改 .controlSize(.small) 去 scaleEffect、订阅添加行重排（不挤单行）、日历色点尺寸
- DataExportSettingsView / AboutSettingsView：说明文字与按钮 controlSize 微调
- 全部沿用系统语义色，不改任何数据逻辑/绑定

## Out of scope
- TabView 结构、分组数量与顺序、窗口尺寸
- 设置项的增删与行为

## Assumptions
- 打磨基准：字号层级 11pt 说明 / 12pt 正文，控件 .controlSize(.small)（开关/按钮）

## Solution
逐文件视觉打磨，不改逻辑：
1. 主题色：选中外圈描边环 + 8pt 间距；自定义颜色行对齐
2. 日历行：Toggle .controlSize(.small)（去 scaleEffect）、色点 8→10pt、权限提示 10→11pt
3. 订阅添加行：改为两行（名称+URL 输入行 / 添加按钮右对齐），输入框占位提示
4. 数据/关于 tab：说明文字统一 11pt、按钮 .controlSize

## Edge cases & risks
| Category | Notes |
|---|---|
| 控件尺寸 | controlSize(.small) 在 Form 行内原生支持，无 hack |
| 兼容 | 不用新 API，全部 macOS 原生控件属性 |

## Acceptance criteria
- AC-1: 主题色圆点选中态有明显外环，与编辑面板颜色选中质感一致
- AC-2: 同步 tab 日历行开关为原生小尺寸（无缩放假象），色点可辨
- AC-3: 权限提示文字 11pt 层级清晰，状态色（橙/红/绿）保留
- AC-4: 订阅日历添加行两行布局，名称/URL 输入框有占位提示，不拥挤
- AC-5: 各 tab 字号/间距层级统一（11 说明 / 12 正文）；所有设置项行为与打磨前一致
