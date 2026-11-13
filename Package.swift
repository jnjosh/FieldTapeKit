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
        // For the FieldCheck app (ADR 0003). It's a product only because the app's Xcode project needs one.
        .library(name: "FieldCheckKit", targets: ["FieldCheckKit"]),
    ],
    targets: [
        .target(name: "FieldTapeKit"),
        .target(name: "FieldCheckKit", dependencies: ["FieldTapeKit"]),
        .testTarget(name: "FieldTapeKitTests", dependencies: ["FieldTapeKit"]),
        .testTarget(name: "FieldCheckKitTests", dependencies: ["FieldCheckKit", "FieldTapeKit"]),
    ]
)
