// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIMeter",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "AIMeterCore"),
        .executableTarget(name: "AIMeter", dependencies: ["AIMeterCore"]),
        .testTarget(name: "AIMeterCoreTests", dependencies: ["AIMeterCore"]),
    ]
)
