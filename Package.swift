// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "FieldTapeKit",
    platforms: [
        .iOS(.v27),
        .macOS(.v27),
    ],
    products: [
        .library(name: "FieldTapeKit", targets: ["FieldTapeKit"]),
    ],
    targets: [
        .target(name: "FieldTapeKit"),
        .testTarget(name: "FieldTapeKitTests", dependencies: ["FieldTapeKit"]),
    ]
)
