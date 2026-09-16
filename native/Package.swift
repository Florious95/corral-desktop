// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentMirrorNative",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentMirrorApp", targets: ["AgentMirrorApp"]),
        .library(name: "Services", targets: ["Services"]),
        .library(name: "Shell", targets: ["Shell"]),
    ],
    targets: [
        .executableTarget(
            name: "AgentMirrorApp",
            dependencies: ["Services", "Shell"],
            path: "Sources/AgentMirrorApp"
        ),
        .target(name: "Services", path: "Sources/Services"),
        .target(name: "Shell", dependencies: ["Services"], path: "Sources/Shell"),
        .testTarget(
            name: "ServicesTests",
            dependencies: ["Services"],
            path: "Tests/ServicesTests"
        ),
        .testTarget(
            name: "ShellTests",
            dependencies: ["Shell"],
            path: "Tests/ShellTests",
            exclude: ["run-checks.sh"]
        ),
    ]
)
