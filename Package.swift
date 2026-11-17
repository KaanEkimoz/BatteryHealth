// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BatteryHealth",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "BatteryHealth", targets: ["BatteryHealth"]),
        .executable(name: "batteryhealthd", targets: ["batteryhealthd"]),
    ],
    dependencies: [
        // Auto-updates from GitHub Releases. Pinned; bump deliberately.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .target(name: "BatteryKit", linkerSettings: [.linkedFramework("IOKit")]),
        .executableTarget(name: "batteryhealthd", dependencies: ["BatteryKit"]),
        .executableTarget(
            name: "BatteryHealth",
            dependencies: ["BatteryKit", .product(name: "Sparkle", package: "Sparkle")],
            // Sparkle.framework is embedded in Contents/Frameworks by scripts/build.sh.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
    ]
)
