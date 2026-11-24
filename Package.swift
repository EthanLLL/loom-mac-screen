// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "loom-mac-screen",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CGVirtualDisplay", path: "Sources/CGVirtualDisplay",
                linkerSettings: [.linkedFramework("CoreGraphics")]),
        .executableTarget(name: "loom-mac-screen", dependencies: ["CGVirtualDisplay"], path: "Sources/loom-mac-screen"),
    ]
)
