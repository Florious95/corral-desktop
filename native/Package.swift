// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentMirrorShell",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "AgentMirrorApp", targets: ["AgentMirrorApp"]),
    ],
    targets: [
        .executableTarget(
            name: "AgentMirrorApp",
            path: "Sources/AgentMirrorApp"
        ),
    ]
)
