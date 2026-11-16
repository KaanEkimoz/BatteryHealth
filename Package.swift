// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BatteryHealth",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "BatteryHealth", targets: ["BatteryHealth"]),
        .executable(name: "batteryhealthd", targets: ["batteryhealthd"]),
    ],
    targets: [
        .target(name: "BatteryKit", linkerSettings: [.linkedFramework("IOKit")]),
        .executableTarget(name: "batteryhealthd", dependencies: ["BatteryKit"]),
        .executableTarget(name: "BatteryHealth", dependencies: ["BatteryKit"]),
    ]
)
