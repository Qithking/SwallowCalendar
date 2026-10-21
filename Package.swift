// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwallowCalendar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "SwallowCalendar",
            targets: ["SwallowCalendar"]
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "SwallowCalendar",
            dependencies: [],
            path: "SwallowCalendar",
            // entitlements 仅 Xcode 打包时使用，SPM 构建不消费，显式排除消除构建警告；
            // Assets.xcassets 走下方 resources 处理，不能同时出现在 exclude（N-3 矛盾修复）
            exclude: ["SwallowCalendar.entitlements"],
            resources: [
                .process("Assets.xcassets")
            ]
        ),
        .testTarget(
            name: "SwallowCalendarTests",
            dependencies: ["SwallowCalendar"],
            path: "SwallowCalendarTests"
        )
    ]
)
