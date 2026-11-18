// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Snowsill",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "SnowsillCore"),
        .executableTarget(name: "Snowsill", dependencies: ["SnowsillCore"]),
        .testTarget(name: "SnowsillTests", dependencies: ["SnowsillCore"]),
    ],
    swiftLanguageModes: [.v5]
)
