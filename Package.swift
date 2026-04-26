// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeSessionMonitor",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClaudeSessionMonitor",
            path: "Sources/ClaudeSessionMonitor"
        )
    ]
)
