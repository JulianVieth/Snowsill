// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SnowPile",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "SnowPileCore"),
        .executableTarget(name: "SnowPile", dependencies: ["SnowPileCore"]),
        .testTarget(name: "SnowPileTests", dependencies: ["SnowPileCore"]),
    ],
    swiftLanguageModes: [.v5]
)
