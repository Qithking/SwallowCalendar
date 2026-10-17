# Bug: 启动时偶发弹出已完成事项 + 提醒弹窗内容超出屏幕

> Status: FIXED
> Mode: (default)
> Severity: functional
> Author: user
> Last updated: 2026-10-17

## Triage

- **Symptom**: A) 应用初始时有一定概率将之前已完成的事项弹出；B) 提醒弹窗部分内容超出屏幕被隐藏
- **Expected**: 已完成事项永不弹窗；弹窗内容完整可见（超出时滚动）
- **Environment**: macOS 27.0.1 / Xcode 27.1 / SwiftData + EventKit 双写架构
- **First seen**: 用户日常使用中发现；代码中已存在 [DEBUG-r1] 调试日志（此前调试遗留）
- **Severity**: functional

## Bug A：已完成事项被弹出

### Root cause（confirmed，因果链完整）

1. 用户标记提醒完成 → `CalendarService.toggleEventCompleted` → `eventStore.calendarItem(withIdentifier:)` 对**已完成的 iCloud 提醒偶发返回 nil**（NOT-FOUND 分支，代码注释已承认此现象）
2. NOT-FOUND 时只更新 SwiftData 缓存 isCompleted=true，**EventKit 未更新（仍 false）→ 两端状态分叉**
3. 重启应用 → `syncReminders`（includeCompleted: true）从 EK 拉到 isCompleted=false → 缓存被**回退为 false**
4. 启动检查 `checkExpiredEvents`（ignoreAlertedCache=true 强制重弹）→ 事项"未完成且过期" → **弹出**
5. 用户再勾选完成 → 若 NOT-FOUND 再次发生 → 循环

"有一定概率"由 NOT-FOUND 的偶发性解释（iCloud 同步状态相关）。

### Fix

- `CalendarService.swift`：`toggleEventCompleted` 改 async；NOT-FOUND 分支新增兜底——通过新增的 `fetchReminderObject(byID:)`（全量 fetchReminders 查找）找到后补写 EK，保证两端一致；兜底仍找不到视为事项已删除（syncReminders 会同步删缓存，不弹）
- 调用点适配 ×3：`ReminderAlertService.markAsCompleted` 改 async（弹窗"全部标记完成"改 Task 串行 await）、`EventPanelView` 两处闭包包 `Task { await ... }`

## Bug B：弹窗内容超出屏幕

### Root cause（机制层锁定）

`showCombinedAlert` 中 scrollView.frame 限高 350，但 documentView（NSTextView）frame 高度为完整内容高（可达 2000px+）。NSAlert 对 accessoryView 布局时可能按 documentView 高度扩展窗口，窗口远超屏幕，顶部对齐后底部内容出屏。

### Fix

- scrollView 改用 Auto Layout 约束固定尺寸（`translatesAutoresizingMaskIntoConstraints = false` + width/heightAnchor），NSAlert 布局读到的高度恒为 min(textHeight, 350)
- textView 补标准 NSScrollView 设置：`autoresizingMask = [.width]`
- 保留 frame 赋值兜底；内容超出 350px 时由垂直滚动条承接

## Verification

> 项目无测试 target，无法编写自动化 failing test（dev-fix Step 2 硬门槛的项目级偏离，如实记录）。

- V-1: `swift build`（非沙箱，Xcode 27.1）→ **Build complete, exit 0**
- V-2: 修复前编译警告 `BackgroundSyncService.swift:53/60 no 'async' operations within 'await'` → 修复后消失（同时修正此前误判：BackgroundSyncService 是 @MainActor 类，调用 MainActor 同步方法本不需要 await，已删多余 await 还原用户原始意图）
- V-3: 逻辑闭环验证：NOT-FOUND 兜底命中 → EK 写入成功 → 重启后 syncReminders 读到 true → 缓存 true → 不弹
- 手动验证步骤（待执行，见 .work/待办计划.md）：
  1. 创建一条已过期的系统提醒 → 在应用内标记完成 → 重启应用 → 确认不再弹出
  2. 观察 Console（subsystem com.swallowcalendar）NOT-FOUND 兜底日志 `save ok(fallback)`
  3. 制造 15+ 条过期未完成提醒 → 启动应用 → 确认弹窗高度受限、可滚动、无内容出屏

## Regression test

- 无（项目无测试 target，见 Verification 说明）

## Pattern analysis

| 搜索方式 | 命中数 | 是否本次同类隐患 |
|---|---|---|
| `git grep -n "calendarItem(withIdentifier" ` | 3 | 是 |

- `CalendarService.swift:812`（updateEvent reminder 分支）：`guard let reminder = eventStore.calendarItem(...) else { return }` —— **静默失败**，编辑已完成 iCloud 提醒时修改不生效且无日志。本次不修（surgical），列入 follow-up。

## Open questions / Follow-ups

- `updateEvent` 的 calendarItem NOT-FOUND 同类隐患（见 Pattern analysis）
- `syncReminders` 回退场景（419-427 行）在 EK 写入失败时仍会回退缓存——兜底修复后触发概率大幅降低，但建议后续在 sync 时对"最近被用户标记完成"的事项加保护（需设计，勿轻动）
- [DEBUG-r1] 调试日志遗留于 4 个文件，问题确认修复后应清理
