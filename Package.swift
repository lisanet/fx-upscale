// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "mx-upscale",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "mx-upscale", targets: ["mx-upscale"]),
        .library(name: "Upscaling", targets: ["Upscaling"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.6.2"),
        .package(url: "https://github.com/Finnvoor/SwiftTUI.git", from: "1.0.4")
    ],
    targets: [
        .executableTarget(
            name: "mx-upscale",
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
    ]
)
