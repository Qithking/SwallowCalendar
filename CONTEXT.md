# Context

## Glossary

| Term | Meaning | Notes |
|---|---|---|
| 循环任务 | 只存一条数据的周期任务：recurrenceType + startDate（下一次/首 occurrence）+ completedOccurrenceDates 完成历史 | ADR-0001；旧"5 实例组"已一次性迁移为单条 |
| occurrence | 循环任务按规则在查询窗口内虚拟展开的某一次出现，非落库行 | 显示对象 id 带 baseEventID 映射供操作回查 |
| completedOccurrenceDates | 循环任务的完成历史真源（单条字段，升序 Date JSON 数组） | 已办列表按其逐条展开历史行 |
| EK 推进式 | 系统日历/提醒侧只建一条普通记录，完成后由应用把 startDate 推进到下一次 | 不使用 EKRecurrenceRule，系统侧看不到未来排期（已接受） |
| 有效期（validStartDate/validEndDate） | 循环任务的生效区间：仅产生落在区间内的 occurrence，两端均为 Date? 可独立缺省 | nil=该端不限制，两端均 nil=不限制；闭区间含端点（结束日当天仍有效）；纯应用侧字段不写 EK；完成后序列冻结在区间内最后一次 occurrence，已完成历史行保留 |
| 外部变更 | 系统提醒事项/日历 app 侧的数据改动（EKEventStore.changed 通知），区别于应用内增删改 | 外部变更走秒级监听+2s 防抖同步（跳过订阅源）；应用内改动走 ContentView 2s 防抖全量同步 |
