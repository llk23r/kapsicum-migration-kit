# `MigrationKit`

Reusable migration toolkit for Swift apps with optional GRDB and CLI layers. No vendor lock-in — bring your own database.

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
try runner.migrate(in: writer)
```

## Table of Contents

- [Why MigrationKit](#why-migrationkit)
- [Installation](#installation)
- [Products](#products)
- [Quick Start](#quick-start)
- [CLI](#cli)
- [API Overview](#api-overview)
- [How It Works](docs/HOW_IT_WORKS.md)
- [Versioning](#versioning)
- [Contributing](#contributing)
- [License](#license)

## Why MigrationKit

- **Reusable** — Keep migration logic in a shared package, decoupled from any single app or service.
- **Deterministic** — Steps are registered with lexicographically ordered identifiers. No implicit ordering surprises.
- **Auditable** — Query migration status, pending steps, and applied identifiers at any time.
- **Rollback-capable** — Optional rollback closures per step, with newest-first undo.
- **Verifiable** — Built-in SQLite integrity checks, foreign key validation, and required index verification.

## Installation

```swift
.package(url: "https://github.com/llk23r/kapsicum-migration-kit.git", from: "0.2.0")
```

Then add the products you need:

```swift
.product(name: "MigrationKit", package: "kapsicum-migration-kit"),
.product(name: "MigrationKitGRDB", package: "kapsicum-migration-kit"),
.product(name: "MigrationKitCLI", package: "kapsicum-migration-kit"),
```

**Requirements:** Swift 6.1+, macOS 13+ / iOS 16+.

## Products

| Product | Description |
|---------|-------------|
| `MigrationKit` | Core types — `MigrationStep`, `MigrationRegistry`, errors, host integration protocol |
| `MigrationKitGRDB` | GRDB-backed runner, verifier, SQL helpers, schema snapshot provider |
| `MigrationKitCLI` | ArgumentParser-based CLI host with migrate/status/rollback/verify/schema-dump commands |
| `migrationkit-cli` | Executable shell wrapper — embed `MigrationCLI.run(arguments:host:)` in your own binary |

## Quick Start

```swift
import MigrationKit
import MigrationKitGRDB

// 1. Define migration steps
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
        rollback: { db in
            try db.drop(table: "users")
        }
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

// 2. Create a runner (validates ordering and uniqueness)
let runner = try GRDBMigrationRunner(steps: steps)

// 3. Run all pending migrations
try runner.migrate(in: writer)

// 4. Check status
let statuses = try runner.migrationStatus(in: writer)
let pending = try runner.pendingMigrationIdentifiers(in: writer)

// 5. Rollback the last migration
try runner.rollbackLastMigration(in: writer)
```

## CLI

The CLI layer provides ActiveRecord-inspired commands. Wire it into your app executable:

```swift
import MigrationKitCLI

let host = MigrationCLIHost(
    runner: runner,
    openWriter: { options in try openDatabase(options) }
)

try MigrationCLI.run(arguments: CommandLine.arguments, host: host)
```

Available commands:

| Command | Description |
|---------|-------------|
| `migrate` | Run pending migrations, optionally `--to <identifier>` |
| `status` | Show up/down status for all registered migrations |
| `rollback` | Rollback migration steps (`--step N`, newest-first) |
| `verify` | Run post-migration integrity checks |
| `schema-dump` | Generate canonical schema snapshot SQL |

## API Overview

**Core (`MigrationKit`):**

| Type | Role |
|------|------|
| `MigrationStep<Database>` | A named migration with `apply` and optional `rollback` closures |
| `MigrationRegistry<Database>` | Validates ordering and uniqueness, exposes manifest and rollback info |
| `MigrationHostIntegration` | Hooks for bootstrap, integrity checks, and post-migration verification |
| `SchemaSnapshotProvider` | Protocol for canonical schema snapshot generation |

**GRDB (`MigrationKitGRDB`):**

| Type | Role |
|------|------|
| `GRDBMigrationRunner` | Full lifecycle — migrate, rollback, status, pending checks |
| `GRDBMigrationVerifier` | SQLite `quick_check`, foreign key validation, required index verification |

**Errors:**

| Error | Thrown when |
|-------|------------|
| `MigrationKitError.duplicateIdentifiers` | Two steps share the same identifier |
| `MigrationKitError.identifiersOutOfOrder` | Steps aren't in lexicographic order |
| `MigrationKitError.rollbackNotDefined` | Rollback requested but step has no rollback closure |
| `GRDBMigrationVerificationError.quickCheckFailed` | SQLite integrity check fails |
| `GRDBMigrationVerificationError.foreignKeyViolations` | Foreign key constraint violations found |

## Versioning

This project follows [Semantic Versioning](https://semver.org). Git tags use the `v` prefix (e.g. `v0.2.0`). Depend on tags/releases for deterministic integration.

See [CHANGELOG.md](CHANGELOG.md) for release history.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup instructions and development workflow.

## License

MIT — see [LICENSE](LICENSE).
