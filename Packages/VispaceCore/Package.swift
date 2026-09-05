// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "VispaceCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "VispaceCore", targets: ["VispaceCore"])
    ],
    targets: [
        .target(name: "VispaceCore"),
        .testTarget(
            name: "VispaceCoreTests",
            dependencies: ["VispaceCore"],
            resources: [.process("Resources")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
