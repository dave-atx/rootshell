// swift-tools-version: 6.0
//
// Standalone tests for dependency-free zmx-related app logic.

import PackageDescription

let package = Package(
    name: "ZmxLogic",
    targets: [
        .target(name: "ZmxLogic"),
        .testTarget(name: "ZmxLogicTests", dependencies: ["ZmxLogic"]),
    ]
)
