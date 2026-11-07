#!/usr/bin/env bash
#
# check-applogger-imports.sh
# 源码导入卫生检查：调用 AppLogger.<logger>.<logMethod>(...) 的文件必须显式 import os。
#
# 为什么用脚本而不是 SwiftPM 测试：
# 缺少 import os 会直接导致编译失败，XCTest 无法运行到检查用例，脚本可在构建前独立执行。
#
# 用法：
#   bash check-applogger-imports.sh
# 退出码：0 = 通过；1 = 存在遗漏（逐个打印 相对路径:行号 -> 调用行）
#
# 仅覆盖本模式：Logger 的 trace/debug/info/notice/warning/error/critical/log 直接调用；
# AppLogger.monthDiag(...) 这类自定义包装函数不在此列（其参数为 String，不依赖 os）。

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT/SwallowCalendar"

CALL_RE='AppLogger\.[A-Za-z0-9_]+\.(trace|debug|info|notice|warning|error|critical|log)[[:space:]]*\('
IMPORT_RE='^[[:space:]]*(@preconcurrency[[:space:]]+)?import[[:space:]]+(os|OSLog)[[:space:]]*$'

if [ ! -d "$SRC" ]; then
  echo "SKIP: 未找到源码目录 $SRC"
  exit 0
fi

fail=0
while IFS= read -r file; do
  # 已显式导入则跳过
  if grep -qE "$IMPORT_RE" "$file"; then
    continue
  fi
  # 跳过注释行；只报告首个真实调用
  hit="$(grep -nE "$CALL_RE" "$file" | grep -vE '^[0-9]+:[[:space:]]*//' | head -n 1 || true)"
  if [ -n "$hit" ]; then
    echo "MISSING import os: ${file#"$ROOT"/}:$hit"
    fail=1
  fi
done < <(grep -rlE "$CALL_RE" "$SRC" --include='*.swift' || true)

if [ "$fail" -ne 0 ]; then
  echo "检查失败：上述文件调用 AppLogger 日志方法但缺少 import os"
  exit 1
fi

echo "OK: 所有调用 AppLogger 日志方法的文件均已显式 import os"
