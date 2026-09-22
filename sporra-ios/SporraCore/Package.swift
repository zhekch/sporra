// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "SporraCore",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "SporraCore", targets: ["SporraCore"]),
    ],
    targets: [
        .target(name: "SporraCore"),
        .testTarget(name: "SporraCoreTests", dependencies: ["SporraCore"]),
    ]
)
