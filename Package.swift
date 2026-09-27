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
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0")
    ],
    targets: [
        .target(name: "CorralContracts"),
        .target(name: "CorralProtocol", dependencies: ["CorralContracts"]),
        .target(name: "CorralServices", dependencies: ["CorralContracts", "CorralProtocol"]),
        .target(
            name: "CorralMetalTerminal",
            dependencies: ["CorralContracts", .product(name: "SwiftTerm", package: "SwiftTerm")]
        ),
        .target(name: "CorralUI", dependencies: ["CorralContracts", "CorralServices", "CorralMetalTerminal"]),
        .executableTarget(
            name: "CorralApp",
            dependencies: [
                "CorralContracts",
                "CorralProtocol",
                "CorralServices",
                "CorralMetalTerminal",
                "CorralUI",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ]
        ),
        .testTarget(name: "CorralContractsTests", dependencies: ["CorralContracts"]),
        .testTarget(
            name: "CorralProtocolTests",
            dependencies: ["CorralProtocol", "CorralContracts"],
            resources: [.process("WireCodecTests/Fixtures")]
        ),
        .testTarget(name: "CorralServicesTests", dependencies: ["CorralServices", "CorralContracts"]),
        .testTarget(name: "CorralMetalTerminalTests", dependencies: ["CorralMetalTerminal", "CorralContracts", "CorralProtocol"]),
        .testTarget(name: "CorralUITests", dependencies: ["CorralUI", "CorralContracts", "CorralMetalTerminal"]),
        .testTarget(
            name: "CorralRegressionTests",
            dependencies: ["CorralContracts", "CorralServices", "CorralUI", "CorralMetalTerminal"]
        ),
        .testTarget(name: "CorralAppTests", dependencies: ["CorralApp", "CorralContracts", "CorralProtocol", "CorralServices", "CorralMetalTerminal", "CorralUI"])
    ]
)
// Production releases use a distinct bundle identity from the development app.
