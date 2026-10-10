// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ColorAnalyze",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ColorAnalyze", targets: ["ColorAnalyze"]),
        .library(name: "ColorCore", targets: ["ColorCore"]),
    ],
    targets: [
        .target(name: "ColorCore"),
        .executableTarget(name: "ColorAnalyze", dependencies: ["ColorCore"]),
        .testTarget(name: "ColorCoreTests", dependencies: ["ColorCore"]),
    ]
)
