// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIMeter",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(name: "AIMeterCore"),
        .executableTarget(
            name: "AIMeter",
            dependencies: ["AIMeterCore", .product(name: "Sparkle", package: "Sparkle")]
        ),
        .testTarget(name: "AIMeterCoreTests", dependencies: ["AIMeterCore"]),
    ]
)
