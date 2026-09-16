// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentMirrorServices",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Services", targets: ["Services"]),
    ],
    targets: [
        .target(name: "Services", path: "Sources/Services"),
        .testTarget(
            name: "ServicesTests",
            dependencies: ["Services"],
            path: "Tests/ServicesTests"
        ),
    ]
)
