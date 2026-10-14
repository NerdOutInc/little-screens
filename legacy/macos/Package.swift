// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AITrmnl",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "ai-trmnl", targets: ["AITrmnl"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "TRMNLCore", dependencies: ["CSQLite"], resources: [.copy("Web")]),
        .executableTarget(name: "AITrmnl", dependencies: ["TRMNLCore"]),
        .testTarget(name: "TRMNLCoreTests", dependencies: ["TRMNLCore"])
    ]
)
