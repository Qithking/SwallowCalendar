//
//  MirrorPolicyGuardTests.swift
//  SwallowCalendarTests
//
//  单一判定源守门用例：扫描源码，发现第二份判定实现即失败。
//  与 check-mirror-policy.sh 同一套规则，避免只靠 review 约定。
//

import XCTest

final class MirrorPolicyGuardTests: XCTestCase {
    private struct Violation {
        let rule: String
        let path: String
        let line: Int
        let text: String
    }

    /// 仓库根目录（由测试文件位置推导）
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // SwallowCalendarTests
        .deletingLastPathComponent()   // 仓库根

    private var sourceRoot: URL { Self.repoRoot.appendingPathComponent("SwallowCalendar") }
    private var policyPath: String { "SwallowCalendar/Models/LunarMirrorPolicy.swift" }

    private func swiftFiles(in directory: String) -> [URL] {
        let base = sourceRoot.appendingPathComponent(directory)
        guard let enumerator = FileManager.default.enumerator(
            at: base,
            includingPropertiesForKeys: nil
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(url)
        }
        return files
    }

    private func scan(
        rule: String,
        directories: [String],
        matches: (String) -> Bool
    ) -> [Violation] {
        var violations: [Violation] = []
        for directory in directories {
            for file in swiftFiles(in: directory) {
                let relative = file.path.replacingOccurrences(of: Self.repoRoot.path + "/", with: "")
                guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
                for (index, line) in content.components(separatedBy: .newlines).enumerated() {
                    guard matches(line) else { continue }
                    violations.append(
                        Violation(rule: rule, path: relative, line: index + 1, text: line)
                    )
                }
            }
        }
        return violations
    }

    private func assertNoViolations(_ violations: [Violation], message: String) {
        guard !violations.isEmpty else { return }
        let details = violations.map { "\($0.rule) \($0.path):\($0.line): \($0.text)" }
        XCTFail("\(message)\n" + details.joined(separator: "\n"))
    }

    /// 旧判定入口禁止复活：supportsMirror / isMirrorEnabled / orphanDeletionKeys 只能由 policy 定义
    func testNoLegacyMirrorDecisionEntryPoints() {
        let violations = scan(rule: "legacy-entry", directories: ["Models", "Services", "Views"]) { line in
            ["LunarMirrorPlan.supportsMirror", "LunarMirrorPlan.isMirrorEnabled", "LunarMirrorPlan.orphanDeletionKeys"]
                .contains { line.contains($0) }
        }
        assertNoViolations(violations, message: "发现旧镜像判定入口（应统一走 LunarMirrorPolicy）")
    }

    /// 删除计划只允许 policy 生成
    func testDeletionPlanOnlyProducedByPolicy() {
        let violations = scan(rule: "delete-plan", directories: ["Models", "Services", "Views"]) { line in
            line.contains("deleteOccurrenceIDs.append")
        }
        .filter { $0.path != policyPath }
        assertNoViolations(violations, message: "删除计划在 policy 之外被拼装")
    }

    /// 界面不得出现「镜像」字样（用户语言：系统提醒事项中按公历日期创建对应提醒）
    func testViewsDoNotMentionMirrorWord() {
        let violations = scan(rule: "ui-wording", directories: ["Views"]) { line in
            line.contains("镜像")
        }
        assertNoViolations(violations, message: "界面/注释出现「镜像」字样，需换成系统提醒语言")
    }

    /// 纯函数层不得引入框架依赖
    func testPolicyLayerHasNoFrameworkImports() {
        guard let content = try? String(contentsOf: sourceRoot.appendingPathComponent("Models/LunarMirrorPolicy.swift"), encoding: .utf8) else {
            return XCTFail("未找到 LunarMirrorPolicy.swift")
        }
        for (index, line) in content.components(separatedBy: .newlines).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("import SwiftData") || trimmed.hasPrefix("import EventKit") {
                XCTFail("policy-import \(policyPath):\(index + 1): \(line)")
            }
        }
    }

    /// Services 必须经由 policy 对账，不得回退到兼容转发层
    func testServicesUsePolicyReconcile() {
        let violations = scan(rule: "service-entry", directories: ["Services"]) { line in
            line.contains("LunarMirrorPlan.reconcile")
        }
        assertNoViolations(violations, message: "Services 直接调用 LunarMirrorPlan.reconcile")
    }
}
