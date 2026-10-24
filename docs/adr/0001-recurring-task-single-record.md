# ADR 0001: 循环任务采用单条存储 + 虚拟 occurrence 展开 + EK 推进式

Status: Accepted
Date: 2026-10-24

## Context

应用创建周期任务（如每天 9 点提醒上班）时一次性生成 5 条实例（EK 日历/提醒 + 本地 SwiftData 各 5 条，groupId 分组），完成后追加下一条，列表同时挂 5 行，用户反馈难以管理。候选方案：a) EK 原生 EKRecurrenceRule 单条；b) 存储单条 + 查询时虚拟展开 occurrence + EK 侧单条推进。应用有三个特性依赖应用自管 occurrence 语义：农历周期（EK 原生不支持）、智能跳过节假日顺延（HolidaySkipResolver）、完成标记 [SC_COMPLETED] 逐实例记录。

## Decision

循环任务只存一条 CachedEvent（recurrenceType + startDate + completedOccurrenceDates JSON），查询时（EventCacheService.getEvents）在时间窗口内按规则虚拟展开 occurrence；EK 日历/提醒侧永远只建一条普通记录（无 rule），完成后应用把其 startDate 推进到下一次未完成 occurrence；编辑即改整条；存量 5 实例组启动时一次性自动迁移为单条。

## Consequences

- 正面：列表永远只显示一条（下一次 occurrence）；农历/跳节假日/完成历史全部应用自持语义零冲突；syncEvents/syncReminders 天然单条同步；管理心智与数据一致
- 负面：系统日历 App 看不到循环任务未来排期（只见下一次日期）；getEvents 返回虚拟 occurrence 波及全部消费方，改动面大；完成历史与 EK 侧历史痕迹不再对应（EK 侧已完成实例迁移时删除）
- 后续约束：新增消费方必须走 getEvents 展开结果的 occurrence 形态消费循环任务，不得假设"1 条 CachedEvent = 1 个显示行"；groupId/groupIndex 字段废弃不再写入（物理保留防迁移风险）
