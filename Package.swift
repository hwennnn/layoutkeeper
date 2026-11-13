// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "layoutkeeper",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "LayoutKeeperAgent", path: "Sources/LayoutKeeperAgent"),
        .executableTarget(
            name: "layoutkeeper",
            path: "Sources/layoutkeeper",
            swiftSettings: [.unsafeFlags(["-swift-version", "5"])],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
            ]
        )
    ]
)
