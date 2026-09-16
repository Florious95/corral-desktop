// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentMirrorNative",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "AgentMirrorApp", targets: ["AgentMirrorApp"]),
        .library(name: "Services", targets: ["Services"]),
    ],
    targets: [
        .executableTarget(
            name: "AgentMirrorApp",
            dependencies: ["Services"],
            path: "Sources/AgentMirrorApp"
        ),
        .target(
            name: "Services",
            path: "Sources/Services"
        ),
        .testTarget(
            name: "ServicesTests",
            dependencies: ["Services"],
            path: "Tests/ServicesTests"
        ),
    ]
)
