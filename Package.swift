// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lux",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "Lux", targets: ["Lux"]),
    ],
    targets: [
        .target(name: "Lux"),
        .testTarget(name: "LuxTests", dependencies: ["Lux"]),
    ]
)
