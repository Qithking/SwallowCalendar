#!/usr/bin/env bash
#
# check-mirror-policy.sh
# 农历镜像「单一判定源」守门脚本：与 MirrorPolicyGuardTests 同一套规则集。
#
# 规则：
#   1. 禁止旧判定入口 LunarMirrorPlan.supportsMirror / isMirrorEnabled / orphanDeletionKeys
#   2. 删除计划只允许 LunarMirrorPolicy 生成（禁止 deleteOccurrenceIDs.append 出现在其它文件）
#   3. Views 中禁止出现「镜像」字样（用户可见/注释一律用系统提醒语言）
#   4. LunarMirrorPolicy.swift 禁止 import SwiftData / EventKit（纯函数层）
#   5. Services 不得直接调用 LunarMirrorPlan.reconcile（必须走 LunarMirrorPolicy）
#   6. 引用 os.Logger 的文件必须显式 import os（复用 check-applogger-imports.sh，
#      覆盖 app 与测试目标；编译阻断项，不再靠另一个脚本的“碰巧执行”兜底）
#
# 用法：bash check-mirror-policy.sh
# 退出码：0 = 通过；1 = 存在违规（逐个打印 相对路径:行号 -> 违规行）

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT/SwallowCalendar"
POLICY="$SRC/Models/LunarMirrorPolicy.swift"

if [ ! -d "$SRC" ]; then
  echo "SKIP: 未找到源码目录 $SRC"
  exit 0
fi

fail=0

report() {
  echo "VIOLATION($1): ${2#"$ROOT"/}:$3 -> $4"
  fail=1
}

# 1. 旧判定入口
while IFS= read -r hit; do
  file="${hit%%:*}"
  rest="${hit#*:}"
  line="${rest%%:*}"
  text="${rest#*:}"
  report "legacy-entry" "$file" "$line" "$text"
done < <(grep -rnE 'LunarMirrorPlan\.(supportsMirror|isMirrorEnabled|orphanDeletionKeys)' "$SRC" --include='*.swift' || true)

# 2. 删除计划唯一生成点
while IFS= read -r hit; do
  file="${hit%%:*}"
  [ "$file" = "$POLICY" ] && continue
  rest="${hit#*:}"
  line="${rest%%:*}"
  text="${rest#*:}"
  report "delete-plan" "$file" "$line" "$text"
done < <(grep -rnE 'deleteOccurrenceIDs\.append' "$SRC" --include='*.swift' || true)

# 3. Views 禁词
while IFS= read -r hit; do
  file="${hit%%:*}"
  rest="${hit#*:}"
  line="${rest%%:*}"
  text="${rest#*:}"
  report "ui-wording" "$file" "$line" "$text"
done < <(grep -rn '镜像' "$SRC/Views" --include='*.swift' || true)

# 4. policy 纯函数层导入约束
if [ -f "$POLICY" ]; then
  while IFS= read -r hit; do
    file="${hit%%:*}"
    rest="${hit#*:}"
    line="${rest%%:*}"
    text="${rest#*:}"
    report "policy-import" "$file" "$line" "$text"
  done < <(grep -nE '^[[:space:]]*import[[:space:]]+(SwiftData|EventKit)' "$POLICY" || true)
fi

# 5. Services 必须走 policy
while IFS= read -r hit; do
  file="${hit%%:*}"
  rest="${hit#*:}"
  line="${rest%%:*}"
  text="${rest#*:}"
  report "service-entry" "$file" "$line" "$text"
done < <(grep -rnE 'LunarMirrorPlan\.reconcile' "$SRC/Services" --include='*.swift' || true)

# 6. os.Logger 导入卫生（与 check-applogger-imports.sh 同一份规则，避免两套实现）
if ! bash "$ROOT/check-applogger-imports.sh"; then
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "检查失败：存在违反单一判定源规则的代码"
  exit 1
fi

echo "OK: 农历镜像判定源约束全部通过"
