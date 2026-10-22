// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacStatsBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "MacStatsBar", path: "Sources/MacStatsBar")
    ]
)
