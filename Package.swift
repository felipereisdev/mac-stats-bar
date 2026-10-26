// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacStatsBar",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "MacStatsBarCore"),
        .executableTarget(name: "MacStatsBar", dependencies: ["MacStatsBarCore"], path: "Sources/MacStatsBar"),
        .testTarget(name: "MacStatsBarCoreTests", dependencies: ["MacStatsBarCore"])
    ]
)
