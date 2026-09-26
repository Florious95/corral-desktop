// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CorralNative",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CorralContracts", targets: ["CorralContracts"]),
        .library(name: "CorralProtocol", targets: ["CorralProtocol"]),
        .library(name: "CorralServices", targets: ["CorralServices"]),
        .library(name: "CorralMetalTerminal", targets: ["CorralMetalTerminal"]),
        .library(name: "CorralUI", targets: ["CorralUI"]),
        .executable(name: "CorralApp", targets: ["CorralApp"])
    ],
    targets: [
        .target(name: "CorralContracts"),
        .target(name: "CorralProtocol", dependencies: ["CorralContracts"]),
        .target(name: "CorralServices", dependencies: ["CorralContracts"]),
        .target(name: "CorralMetalTerminal", dependencies: ["CorralContracts"]),
        .target(name: "CorralUI", dependencies: ["CorralContracts"]),
        .executableTarget(
            name: "CorralApp",
            dependencies: [
                "CorralContracts",
                "CorralProtocol",
                "CorralServices",
                "CorralMetalTerminal",
                "CorralUI"
            ]
        ),
        .testTarget(name: "CorralContractsTests", dependencies: ["CorralContracts"]),
        .testTarget(
            name: "CorralProtocolTests",
            dependencies: ["CorralProtocol", "CorralContracts"],
            resources: [.process("WireCodecTests/Fixtures")]
        ),
        .testTarget(name: "CorralServicesTests", dependencies: ["CorralServices", "CorralContracts"]),
        .testTarget(name: "CorralMetalTerminalTests", dependencies: ["CorralMetalTerminal", "CorralContracts"]),
        .testTarget(name: "CorralUITests", dependencies: ["CorralUI", "CorralContracts"])
    ]
)
// M0 intentionally has no external package dependencies. The App target is the sole concrete composition root.
