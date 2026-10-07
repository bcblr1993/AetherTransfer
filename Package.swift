// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AetherTransfer",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "AetherTransfer", targets: ["AetherTransferApp"]),
        .executable(name: "AetherTransferBenchmarks", targets: ["AetherTransferBenchmarks"]),
        .library(name: "AetherTransferCore", targets: ["AetherTransferCore"])
    ],
    targets: [
        .target(name: "CTransfer", cSettings: [.unsafeFlags(["-I/opt/homebrew/opt/curl/include"])],
                linkerSettings: [.unsafeFlags(["-L/opt/homebrew/opt/curl/lib"]), .linkedLibrary("curl")]),
        .target(name: "AetherTransferCore", dependencies: ["CTransfer"]),
        .executableTarget(name: "AetherTransferApp", dependencies: ["AetherTransferCore"]),
        .executableTarget(name: "AetherTransferBenchmarks", dependencies: ["AetherTransferCore"], path: "Tools/PerformanceProbe"),
        .testTarget(name: "AetherTransferCoreTests", dependencies: ["AetherTransferCore"])
    ]
)
