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
        // For the FieldCheck app (ADR 0003). They're products only because the app's Xcode project needs them.
        .library(name: "FieldCheckKit", targets: ["FieldCheckKit"]),
        .library(name: "FieldTapeConformance", targets: ["FieldTapeConformance"]),
    ],
    targets: [
        .target(name: "FieldTapeKit"),
        // Baselines/ holds a copy of each firmware/<version>/baseline.json, so FieldCheck can compare a run on the
        // iPad. A test keeps the copies the same as the repository's (ADR 0003, section 4).
        .target(name: "FieldCheckKit", dependencies: ["FieldTapeKit"], resources: [.copy("Baselines")]),
        // Uses only FieldTapeKit's public API, so it checks what apps see.
        .target(name: "FieldTapeConformance", dependencies: ["FieldTapeKit"]),
        .testTarget(name: "FieldTapeKitTests", dependencies: ["FieldTapeKit"]),
        .testTarget(name: "FieldCheckKitTests", dependencies: ["FieldCheckKit", "FieldTapeKit"]),
        .testTarget(name: "FieldTapeConformanceTests", dependencies: ["FieldTapeConformance", "FieldTapeKit"]),
    ]
)
