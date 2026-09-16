// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentMirrorNative",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Services", targets: ["Services"]),
        .library(name: "Shell", targets: ["Shell"]),
    ],
    targets: [
        .target(name: "Services", path: "Sources/Services"),
        .target(name: "Shell", path: "Sources/Shell"),
        .testTarget(
            name: "ServicesTests",
            dependencies: ["Services"],
            path: "Tests/ServicesTests"
        ),
        .testTarget(
            name: "ShellTests",
            dependencies: ["Shell"],
            path: "Tests/ShellTests"
        ),
    ]
)
