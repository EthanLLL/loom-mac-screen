// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "loom-mac-screen",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "loom-mac-screen", path: "Sources/loom-mac-screen"),
    ]
)
