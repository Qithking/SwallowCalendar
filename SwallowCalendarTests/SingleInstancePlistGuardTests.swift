//
//  SingleInstancePlistGuardTests.swift
//  SwallowCalendarTests
//
//  单实例守门用例：Info.plist 侧 LSMultipleInstancesProhibited 配置丢失即失败。
//  机制说明：Xcode 26.4 不存在 INFOPLIST_KEY_LSMultipleInstancesProhibited
//  build setting（xcspec 白名单外会被静默忽略），故经独立 Info.plist +
//  INFOPLIST_FILE 与 GENERATE_INFOPLIST_FILE 生成内容合并实现。
//

import XCTest

final class SingleInstancePlistGuardTests: XCTestCase {
    /// 仓库根目录（由测试文件位置推导）
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // SwallowCalendarTests
        .deletingLastPathComponent()   // 仓库根

    private func readText(_ relativePath: String) -> String? {
        try? String(
            contentsOf: Self.repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    /// 两个 build configuration（Debug/Release）都必须配置 INFOPLIST_FILE，
    /// 丢失任一侧则该侧构建产物不再合并 LSMultipleInstancesProhibited
    func testPbxprojConfiguresInfoPlistFile() {
        let content = readText("SwallowCalendar.xcodeproj/project.pbxproj")
        guard let content else { return XCTFail("未找到 project.pbxproj") }
        let count = content
            .components(separatedBy: "INFOPLIST_FILE = SwallowCalendar/Info.plist")
            .count - 1
        XCTAssertGreaterThanOrEqual(
            count, 2,
            "INFOPLIST_FILE 配置少于 2 处（需 Debug + Release 各一），单实例声明会缺侧"
        )
    }

    /// 独立 Info.plist 必须存在且声明禁止多实例
    func testInfoPlistProhibitsMultipleInstances() throws {
        guard let content = readText("SwallowCalendar/Info.plist") else {
            return XCTFail("未找到 SwallowCalendar/Info.plist（单实例声明丢失）")
        }
        XCTAssertTrue(
            content.contains("LSMultipleInstancesProhibited"),
            "Info.plist 缺少 LSMultipleInstancesProhibited"
        )
        XCTAssertTrue(
            content.contains("<true/>"),
            "LSMultipleInstancesProhibited 未声明为 true"
        )
    }

    /// SPM 构建路径需显式排除 Info.plist（与 entitlements 同模式），
    /// 否则 executableTarget 资源阶段产生 unhandled 警告
    func testPackageSwiftExcludesInfoPlist() {
        let content = readText("Package.swift")
        guard let content else { return XCTFail("未找到 Package.swift") }
        XCTAssertTrue(
            content.contains("\"Info.plist\""),
            "Package.swift 未排除 Info.plist"
        )
    }
}
