# MigrationKit
Reusable migration toolkit for Swift apps with optional GRDB and CLI layers.

## Installation
```swift
.package(url: "https://github.com/llk23r/kapsicum-migration-kit.git", from: "0.2.0")
```

Available products:
- `MigrationKit` (core types/registry/errors)
- `MigrationKitGRDB` (GRDB-backed migration runner/helpers/verifier)
- `MigrationKitCLI` (ArgumentParser-based CLI host/commands)
- `migrationkit-cli` (executable shell wrapper)

## Example
```swift
import MigrationKit
import MigrationKitGRDB

let steps: [MigrationStep<Database>] = [
    .init(
        identifier: "0001_create_items",
        sourceFile: "M0001_CreateItems.swift",
        apply: { db in
            try db.create(table: "items") { t in
                t.column("id", .integer).primaryKey()
            }
        }
    )
]

let runner = try GRDBMigrationRunner(steps: steps)
```

## Versioning
Semantic Versioning with `v` tags.
