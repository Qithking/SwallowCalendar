# Bug: 应用启动生成空白窗口 "SwallowCalendar Settings"

> Status: FIXED
> Author: user
> Last updated: 2026-10-18

## Triage

- **Symptom**: 应用启动后出现一个空白窗口，标题 "SwallowCalendar Settings"
- **Expected**: 应用为菜单栏应用，启动后不应有任何可见窗口（主面板由状态栏图标点击控制）
- **Repro 起点**: 部署后 `open /Applications/SwallowCalendar.app` 启动应用
- **Environment**: macOS 15+，SwiftUI App + AppDelegate 自管 FloatingPanel
- **First seen**: 编辑面板/设置窗口引入 `NSApp.activate(ignoringOtherApps:)` 后的近期部署
- **Severity**: 影响功能（多余空白窗口）

## Root cause

**第一次修复（换 Window scene）无效后，用 CGWindowList 实证修正根因**：

macOS 15+ 上，SwiftUI scene 生命周期的应用被激活（`open`/`NSApp.activate`）且无可见标准窗口时，系统会自动把默认 scene 窗口拉出来（无论 scene 是 Settings 还是 Window）。项目全部 UI（面板/设置/编辑/提醒）都由 AppDelegate 的 AppKit 自管窗口承载，SwiftUI scene 唯一作用是保活——只要有 SwiftUI scene，空白窗口就会被系统拉出。Settings scene 时窗口标题为"应用名 + Settings"。

实证：CGWindowList 枚举修复前进程——存在 layer=0 900×450 可见空白窗口（SwiftUI scene 默认空窗口特征），与 SettingsWindowManager(500 宽)/EditEventWindowManager(340 宽) 尺寸均不符。

## Fix

SwallowCalendarApp.swift：删除 SwiftUI `App` struct，改纯 NSApplication 启动（AppKit 应用标准做法）：

```swift
@main
enum SwallowCalendarApp {
    // NSApplication 对 delegate 是弱引用，必须静态强持有防止释放
    private static let appDelegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = appDelegate
        app.run()
    }
}
```

没有 SwiftUI scene 就没有 scene 窗口可被系统拉出，根治。

## Verify

- **CGWindowList 实证**：修复后启动进程（pid 26847）窗口枚举仅剩 layer=25 状态栏面板（340×600），layer=0 空白窗口消失
- 回归：状态栏点击面板、设置窗口、编辑窗口打开正常（待用户验收）
