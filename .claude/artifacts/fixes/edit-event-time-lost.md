# Fix: edit-event-time-lost

> Status: FIXED（待用户验收）
> Date: 2026-10-18
> Mode: 默认（1 个根因假设，静态定位确认）

## Triage

- **Symptom**：点击"修改事项"按钮编辑保存后，hover 弹窗显示的时间没有小时（显示"全天"）
- **Expected**：编辑为带时间的事项后，弹窗/行内显示 HH:mm
- **Repro**：事项原为全天（或无到期时间，系统视为全天）→ 点修改 → 关闭"全天事件"开关并设置时间 → 保存 → hover 弹窗无小时
- **First seen**：编辑保存后立即出现，全量同步后才恢复
- **Severity**：影响功能（时间信息丢失显示）

## Hypothesis

H1（confirmed）：`CalendarService.updateEvent` 更新缓存时不更新 `isAllDay`，EditEventSheet 也不传该参数。用户把全天/无到期事项改为带时间保存后：EK 侧按 endDate 推断正确写入时间 components，但缓存 `isAllDay` 保持 true → `CalendarEvent.hasTime = !isAllDay && startDate != nil` = false → UI 显示"全天"。反向（带时间改全天）同样产生缓存与 EK 不一致（EK 全天但缓存显示 HH:mm）。

排除：EK 写入路径（components 按 endDate 推断写入正确）；calendarItem 取 nil（guard return 在缓存更新前，数据不会变）。

## Root cause

updateEvent 是"部分更新"语义（nil 不动），但 isAllDay 缺失于参数与三处写入（EKReminder components、EKEvent.isAllDay、cached.isAllDay）。EditEventSheet 保存时用户可见的"全天事件"开关状态没有传导到任何持久层，只影响了 endDate 是否为 nil——而 EKReminder 分支按 endDate 推断恰好把时间写对了，唯独缓存 isAllDay 不跟随 → 缓存与 EK 数据不一致。

## Fix

1. `CalendarService.updateEvent` 增加 `isAllDay: Bool? = nil` 参数：
   - EKReminder 分支：components 时间写入改为显式依据 isAllDay（nil 时保持旧 endDate 推断，兼容旧调用）
   - EKEvent 分支：`event.isAllDay = isAllDay`
   - 缓存：`cached.isAllDay = isAllDay`
2. `EditEventSheet.saveEvent` 传 `isAllDay: isAllDay`

## Defense-in-depth

无（根因单一；旧调用兼容由默认参数 nil 保证，无回归面）。

## Verify

- swift build exit 0（0.15s）；部署 /Applications 重签运行（pid 21268）
- 手动验证（待用户）：全天事项 → 编辑关闭全天开关设时间保存 → hover 弹窗显示 HH:mm；反向开全天开关保存 → 显示"全天"；普通编辑（不改开关）行为不变
