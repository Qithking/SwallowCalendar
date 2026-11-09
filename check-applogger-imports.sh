#!/usr/bin/env bash
#
# check-applogger-imports.sh
# 源码导入卫生检查：引用 os.Logger（AppLogger 日志器成员 / 裸 Logger 构造）的文件必须显式 import os。
#
# 为什么用脚本而不是 SwiftPM 测试：
# 缺少 import os 会直接导致编译失败，XCTest 无法运行到检查用例，脚本可在构建前独立执行。
#
# 覆盖面（不按目录白名单）：
#   - 仓库内所有 *.swift，包含 app target 与测试 target；
#   - 跳过 .build / .git 下的构建产物。
#
# 识别（宁可多报，不可漏报编译阻断项）：
#   - AppLogger.cache.error(...) 单行调用；
#   - 跨行链式/取别名：只要出现 AppLogger 的 os.Logger 成员引用（cache/sync/ics/reminder/settings/ui/monthQuery）；
#   - 裸 Logger(...) 构造（AppLogger.swift 定义处）；
#   - AppLogger 上的扩展方法调用（本质仍是 AppLogger.<logger>.<method>）。
#
# 不误报：
#   - 注释（//、///、/* */）里的 AppLogger 文本；
#   - 字符串字面量里的 AppLogger 文本；
#   - AppLogger.monthDiag / monthDiagEnabled（纯 Swift String 入口，不依赖 os）。
#
# 用法：bash check-applogger-imports.sh
# 退出码：0 = 通过；1 = 存在遗漏（逐个打印 相对路径:行号 -> 调用行）

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail=0
scanned=0

while IFS= read -r file; do
  scanned=$((scanned + 1))
  # awk 负责：去注释 / 去字符串 → 判定 import os → 判定 Logger 引用（输出首个命中行）
  out="$(awk '
    BEGIN { inBlock = 0; hasImport = 0; found = 0; firstLine = 0; firstText = "" }
    {
      line = $0
      clean = ""
      i = 1
      n = length(line)
      while (i <= n) {
        two = substr(line, i, 2)
        if (inBlock) {
          if (two == "*/") { inBlock = 0; i += 2 } else { i++ }
          continue
        }
        if (two == "/*") { inBlock = 1; i += 2; continue }
        if (two == "//") { break }
        c = substr(line, i, 1)
        if (c == "\"") {
          i++
          while (i <= n) {
            c2 = substr(line, i, 1)
            if (c2 == "\\") { i += 2; continue }
            if (c2 == "\"") { i++; break }
            i++
          }
          clean = clean " "
          continue
        }
        clean = clean c
        i++
      }
      if (clean ~ /^[[:space:]]*(@preconcurrency[[:space:]]+)?import[[:space:]]+(os|OSLog)[[:space:]]*$/) hasImport = 1
      # os.Logger 成员引用（含跨行链式与扩展方法）；monthDiag* 不在此列
      if (clean ~ /AppLogger[.](cache|sync|ics|reminder|settings|ui|monthQuery)([^A-Za-z0-9_]|$)/) {
        if (!found) { firstLine = NR; firstText = line }
        found = 1
      }
      # 裸 Logger 构造（AppLogger.swift 定义处）
      if (!found && clean ~ /(^|[^A-Za-z0-9_.])Logger[[:space:]]*[(]/) {
        firstLine = NR; firstText = line; found = 1
      }
    }
    END {
      if (found && !hasImport) printf "%d:%s\n", firstLine, firstText
    }
  ' "$file")"

  if [ -n "$out" ]; then
    echo "MISSING import os: ${file#"$ROOT"/}:$out"
    fail=1
  fi
done < <(find "$ROOT" -name '*.swift' \
  -not -path "$ROOT/.build/*" \
  -not -path "$ROOT/.git/*" | sort)

if [ "$fail" -ne 0 ]; then
  echo "检查失败：上述文件引用 os.Logger 但缺少 import os"
  exit 1
fi

echo "OK: 所有引用 os.Logger 的文件均已显式 import os（扫描 $scanned 个 Swift 文件）"
