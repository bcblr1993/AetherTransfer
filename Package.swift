// swift-tools-version: 6.0
import PackageDescription
import Foundation

let curlPrefix = ProcessInfo.processInfo.environment["AT_CURL_PREFIX"]
    ?? "\(Context.packageDirectory)/.build/protocol-runtime"
precondition(FileManager.default.fileExists(atPath: "\(curlPrefix)/lib/libcurl.4.dylib"),
             "Run ./scripts/build_protocol_runtime.sh before Swift commands; system curl cannot substitute the tested SFTP runtime.")
let runtimeBuildID = (try? String(contentsOfFile: "\(curlPrefix)/.aether-build", encoding: .utf8))?
    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "external"

let package = Package(
    name: "AetherTransfer",
    defaultLocalization: "en",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "AetherTransfer", targets: ["AetherTransferApp"]),
        .executable(name: "AetherTransferBenchmarks", targets: ["AetherTransferBenchmarks"]),
        .library(name: "AetherTransferCore", targets: ["AetherTransferCore"])
    ],
    targets: [
        .target(name: "CTransfer", cSettings: [.unsafeFlags(["-I\(curlPrefix)/include"]),
                                              .define("AT_PROTOCOL_RUNTIME_BUILD", to: "\"\(runtimeBuildID)\"")],
                linkerSettings: [.unsafeFlags(["-L\(curlPrefix)/lib"]), .linkedLibrary("curl")]),
        .target(name: "AetherTransferCore", dependencies: ["CTransfer"], resources: [.process("Resources")]),
        .executableTarget(name: "AetherTransferApp", dependencies: ["AetherTransferCore"]),
        .executableTarget(name: "AetherTransferBenchmarks", dependencies: ["AetherTransferCore"], path: "Tools/PerformanceProbe"),
        .testTarget(name: "AetherTransferCoreTests", dependencies: ["AetherTransferCore"])
    ]
)
