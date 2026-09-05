// swift-tools-version: 6.0
//
// Standalone tests for dependency-free login-shell-command logic.

import PackageDescription

let package = Package(
    name: "LoginShellLogic",
    targets: [
        .target(name: "LoginShellLogic"),
        .testTarget(name: "LoginShellLogicTests", dependencies: ["LoginShellLogic"]),
    ]
)
