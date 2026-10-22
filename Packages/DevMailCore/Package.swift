// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "DevMailCore",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "DevMailCore", targets: ["DevMailCore"])
    ],
    targets: [
        .target(name: "DevMailCore"),
        .testTarget(
            name: "DevMailCoreTests",
            dependencies: ["DevMailCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
