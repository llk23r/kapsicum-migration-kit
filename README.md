# `MigrationKit`

A migration toolkit for Swift apps. The core module is database-agnostic; a GRDB runner and a CLI layer ship alongside it.

```swift
import MigrationKit
import MigrationKitGRDB

let steps: [MigrationStep<Database>] = [
    .init(identifier: "0001_create_items", sourceFile: "M0001_CreateItems.swift") { db in
        try db.create(table: "items") { t in
            t.column("id", .integer).primaryKey()
        }
    }
]

let runner = try GRDBMigrationRunner(steps: steps)
try runner.migrate(in: writer)
```

## Table of Contents

- [Why this exists](#why-this-exists)
- [Installation](#installation)
- [Products](#products)
- [Quick Start](#quick-start)
- [CLI](#cli)
- [API Overview](#api-overview)
- [How It Works](docs/HOW_IT_WORKS.md)
- [Versioning](#versioning)
- [Contributing](#contributing)
- [License](#license)

## Why this exists

Migration logic tends to live inside the app that needs it, which makes it hard to share across targets or test in isolation. MigrationKit pulls that logic into a standalone package.

Steps are registered with lexicographically ordered identifiers (e.g. `0001_create_users`, `0002_add_email`). The registry validates uniqueness and ordering at init time, before anything touches the database. Each step can optionally declare a rollback closure. After a run, the verifier checks SQLite integrity and foreign keys automatically.

## Installation

Requires Swift 6.1+, macOS 13+ / iOS 16+.

```swift
.package(url: "https://github.com/llk23r/kapsicum-migration-kit.git", from: "0.2.0")
```

Then add whichever products you need to your target:

```swift
.product(name: "MigrationKit", package: "kapsicum-migration-kit"),
.product(name: "MigrationKitGRDB", package: "kapsicum-migration-kit"),
.product(name: "MigrationKitCLI", package: "kapsicum-migration-kit"),
```

## Products

| Product | What it contains |
|---------|-----------------|
| `MigrationKit` | Core types: `MigrationStep`, `MigrationRegistry`, errors, host integration hooks |
| `MigrationKitGRDB` | GRDB-backed runner, verifier, SQL helpers, schema snapshot provider |
| `MigrationKitCLI` | ArgumentParser CLI host with migrate/status/rollback/verify/schema-dump commands |
| `migrationkit-cli` | Executable shell; embed `MigrationCLI.run(arguments:host:)` in your own binary |

## Quick Start

Define steps, create a runner, migrate. The runner builds a `MigrationRegistry` internally, so ordering and uniqueness checks happen at init.

```swift
import MigrationKit
import MigrationKitGRDB

let steps: [MigrationStep<Database>] = [
    .init(
        identifier: "0001_create_users",
        sourceFile: "M0001_CreateUsers.swift",
        apply: { db in
            try db.create(table: "users") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("email", .text).notNull().unique()
            }
        },
        rollback: { db in try db.drop(table: "users") }
    ),
    .init(
        identifier: "0002_add_avatar_url",
        sourceFile: "M0002_AddAvatarURL.swift",
        apply: { db in
            try db.alter(table: "users") { t in
                t.add(column: "avatar_url", .text)
            }
        }
    )
]

let runner = try GRDBMigrationRunner(steps: steps)

// Apply all pending migrations
try runner.migrate(in: writer)

// Check what has been applied
let statuses = try runner.migrationStatus(in: writer)
let pending = try runner.pendingMigrationIdentifiers(in: writer)

// Undo the last applied migration
try runner.rollbackLastMigration(in: writer)
```

## CLI

Wire `MigrationCLI` into your executable to get ActiveRecord-style commands:

```swift
let host = MigrationCLIHost(
    runner: runner,
    openWriter: { options in try openDatabase(options) }
)
try MigrationCLI.run(arguments: CommandLine.arguments, host: host)
```

| Command | What it does |
|---------|-------------|
| `migrate` | Apply pending migrations, optionally `--to <identifier>` |
| `status` | Print up/down for every registered migration |
| `rollback` | Undo the last N steps (`--step N`) |
| `verify` | Run integrity checks without migrating |
| `schema-dump` | Write canonical schema SQL to a file |

## API Overview

Core (`MigrationKit`):

| Type | What it does |
|------|-------------|
| `MigrationStep<Database>` | Holds an identifier, source file, apply closure, and optional rollback closure |
| `MigrationRegistry<Database>` | Validates ordering and uniqueness; exposes the manifest and rollback-capable identifiers |
| `MigrationHostIntegration` | Optional hooks for schema bootstrap, integrity checks, and post-migration verification |
| `SchemaSnapshotProvider` | Protocol for generating a canonical schema snapshot |

GRDB (`MigrationKitGRDB`):

| Type | What it does |
|------|-------------|
| `GRDBMigrationRunner` | Migrate forward, roll back, query status and pending steps |
| `GRDBMigrationVerifier` | SQLite `quick_check`, foreign key validation, required index checks |

Errors:

| Error | When it's thrown |
|-------|-----------------|
| `MigrationKitError.duplicateIdentifiers` | Two steps share the same identifier |
| `MigrationKitError.identifiersOutOfOrder` | Steps aren't in lexicographic order |
| `MigrationKitError.rollbackNotDefined` | Rollback requested on a step that doesn't have one |
| `GRDBMigrationVerificationError.quickCheckFailed` | SQLite integrity check fails |
| `GRDBMigrationVerificationError.foreignKeyViolations` | Foreign key violations found |

## Versioning

[Semantic Versioning](https://semver.org). Tags use the `v` prefix (e.g. `v0.2.0`). See [CHANGELOG.md](CHANGELOG.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT. See [LICENSE](LICENSE).
