// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "DevMailCore",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "DevMailCore", targets: ["DevMailCore"]),
        // The `dev-mail` command, minus its `main.swift`, which lives in the app's `dev-mail` tool target.
        .library(name: "DevMailCLI", targets: ["DevMailCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2")
    ],
    targets: [
        .target(name: "DevMailCore"),
        .target(
            name: "DevMailCLI",
            dependencies: [
                "DevMailCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "DevMailCoreTests",
            dependencies: ["DevMailCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "DevMailCLITests",
            dependencies: ["DevMailCLI"]
        ),
    ]
)
