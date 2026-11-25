// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "JeskeLooper",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "LooperCore", path: "Sources/LooperCore"),
        .executableTarget(name: "JeskeLooper", dependencies: ["LooperCore"], path: "Sources/JeskeLooper"),
        .executableTarget(name: "LooperChecks", dependencies: ["LooperCore"], path: "Sources/LooperChecks"),
    ]
)
