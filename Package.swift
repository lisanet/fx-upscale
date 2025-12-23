// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "fx-upscale",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "fx-upscale", targets: ["fx-upscale"]),
        .library(name: "Upscaling", targets: ["Upscaling"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.6.2"),
        .package(url: "https://github.com/Finnvoor/SwiftTUI.git", from: "1.0.4")
    ],
    targets: [
        .executableTarget(
            name: "fx-upscale",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "SwiftTUI", package: "SwiftTUI"),
                "Upscaling"
            ]
        ),
        .target(
            name: "Upscaling",
            resources: [
                .process("Shaders/Sharpen.metal"),
            ]
        ),
        .testTarget(
            name: "UpscalingTests",
            dependencies: ["Upscaling"],
            resources: [.process("Resources")]
        )
    ]
)
