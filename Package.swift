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
    dependencies: [
        .package(url: "https://github.com/apple/swift-collections", from: "1.1.0")
    ],
    targets: [
        .executableTarget(
            name: "SwallowCalendar",
            dependencies: [],
            path: "SwallowCalendar",
            exclude: ["Assets.xcassets"],
            resources: [
                .process("Assets.xcassets")
            ]
        )
    ]
)
