// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "MigrationKit",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(
            name: "MigrationKit",
            targets: ["MigrationKit"]
        ),
        .library(
            name: "MigrationKitGRDB",
            targets: ["MigrationKitGRDB"]
        ),
        .library(
            name: "MigrationKitCLI",
            targets: ["MigrationKitCLI"]
        ),
        .executable(
            name: "migrationkit-cli",
            targets: ["migrationkit-cli"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/mezhevikin/GRDB.SQLCipher.swift.git", branch: "master"),
        .package(url: "https://github.com/sqlcipher/SQLCipher.swift.git", exact: "4.11.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.6.0"),
    ],
    targets: [
        .target(
            name: "MigrationKit"
        ),
        .target(
            name: "MigrationKitGRDB",
            dependencies: [
                "MigrationKit",
                .product(name: "GRDB", package: "GRDB.SQLCipher.swift"),
            ]
        ),
        .target(
            name: "MigrationKitCLI",
            dependencies: [
                "MigrationKit",
                "MigrationKitGRDB",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "migrationkit-cli",
            dependencies: ["MigrationKitCLI"]
        ),
        .testTarget(
            name: "MigrationKitTests",
            dependencies: [
                "MigrationKit",
                "MigrationKitGRDB",
                .product(name: "GRDB", package: "GRDB.SQLCipher.swift"),
            ]
        ),
    ]
)
