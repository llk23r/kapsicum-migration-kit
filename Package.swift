// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MigrationKit",
    products: [
        .library(
            name: "MigrationKit",
            targets: ["MigrationKit"]
        ),
    ],
    targets: [
        .target(
            name: "MigrationKit"
        ),
        .testTarget(
            name: "MigrationKitTests",
            dependencies: ["MigrationKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
