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
- [Ledger, revisions and squash on merge](#ledger-revisions-and-squash-on-merge)
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

// See what reversing everything after 0001 would take away, then do it in one transaction
let report = try runner.rollbackReport(.to("0001_create_users"), in: writer)
try runner.rollback(.to("0001_create_users"), in: writer, expecting: report.identifiers)
```

A rollback closure must only change the database: `rollbackReport` runs it in a savepoint that is
then undone, as SQLite undoes any rollback that fails.

## CLI

Wire `MigrationCLI` into your executable to get ActiveRecord-style commands:

```swift
let host = MigrationCLIHost(
    runner: runner,
    openWriter: { options in try openDatabase(options) },
    schemaSnapshotProvider: GRDBSchemaSnapshotProvider(
        migrate: { queue in
            try runner.migrate(in: queue)
        }
    )
)
try MigrationCLI.run(arguments: CommandLine.arguments, host: host)
```

`MigrationCLI.run(arguments:host:)` accepts either:
- `["migrationkit", "status", ...]`
- `["status", ...]`

| Command | What it does |
|---------|-------------|
| `migrate` | Apply pending migrations, optionally `--to <identifier>` |
| `status` | Print up/down for every registered migration |
| `rollback` | Reverse the last N steps (`--step N`) or every step after one (`--to <identifier>`) in one transaction; prints what goes first, `--dry-run` stops there |
| `verify` | Run integrity checks without migrating |
| `schema-dump` | Write canonical schema SQL to a file (requires `schemaSnapshotProvider`) |

## Ledger, revisions and squash on merge

`grdb_migrations` says which identifiers ran. It cannot say *which definition* of an identifier
ran, or which build ran it, and a database another branch migrated looks the same as one that
belongs to a newer build. The runner keeps a ledger next to it:

```sql
CREATE TABLE archive_migration_ledger (
  identifier TEXT PRIMARY KEY,
  revision INTEGER,                 -- NULL: applied before the ledger, or by a build without it
  applied_commit TEXT, applied_branch TEXT, applied_at REAL NOT NULL
);
```

- **Written with each step.** Every step writes its row inside the transaction GRDB runs it in
  (`inTransaction(.immediate)`, also under deferred foreign key checks), with its `revision` and
  the `MigrationProvenance` the host passed the runner. A step that throws leaves no row.
- **Deleted with each rollback**, in the rollback's own transaction.
- **Reconciled** by `reconcileLedger(in:)`, which `migrate` also runs: an applied identifier
  without a row gets one with a NULL revision; a row whose identifier is not applied is removed.
  `grdb_migrations` stays the source of truth. The drift is measured in a read, and a write
  transaction opens only when there is some, so migrating an up-to-date database writes nothing.

```swift
let runner = try GRDBMigrationRunner(
    steps: steps,
    provenance: MigrationProvenance(commit: buildCommit, branch: buildBranch)
)
try runner.reconcileLedger(in: writer)   // when the database opens
let diff = try runner.diff(in: writer, mainKnown: releasedIdentifiers)
// diff.behind:   registered steps not applied
// diff.ahead:    applied identifiers this build neither registers nor supersedes
// diff.diverged:   steps applied at another revision (see below)
// diff.incomplete: steps whose superseded chain is only partly applied (see below)
```

### Revision

`MigrationStep.revision` (default 1) names a step's definition. A step is frozen once it ran
anywhere that matters: further changes go in a new migration. `diff` reports a step as
**diverged** when the ledger recorded another revision for it, except for identifiers in
`mainKnown` (released migrations are append-only and never compared) and for a NULL revision
(unknown, never diverged; the host decides whether to ask).

### Supersedes

`MigrationStep.supersedes` lists the migrations a step replaces, as `MigrationReference`s:
`"0065_add_refs"` matches that identifier at any revision, `"0091_x@1"` only at revision 1 (or at
an unknown one). When **every** reference is applied:

- the step counts as applied: `diff` does not list it as behind, `migrationStatus` shows it up,
  and a rollback can reverse it;
- the superseded identifiers are neither `ahead` nor unknown to `rollbackBlockedByUnknownMigrations`:
  the registered step stands for them;
- `migrate` does **not** run it: it registers the step with GRDB as a migration that only writes
  its ledger row (its revision, the current provenance), so GRDB records its identifier in
  `grdb_migrations`, atomically, in its own transaction. A squash that kept its name is already in
  `grdb_migrations`, so GRDB skips it and its row keeps the revision that ran; the chain still
  covers it. The superseded rows stay, so a build that still registers them sees them applied;
- rolling the step back reverses its schema and removes its rows **and** the superseded ones, so
  the next `migrate` runs it as on a fresh database.

When only **some** references are applied, the database ran part of a chain the step cannot
finish: `diff` lists the step under `incomplete` (whatever `mainKnown` says) and `migrate` throws
`supersededChainIncomplete`, decided from a read, before writing anything. Roll the chain back with the build that
applied it.

The registry refuses a reference that names a registered step, a reference named twice, and a step
naming itself other than at an earlier revision.

Renumbering on merge is the simplest case: a branch ran `0065_add_refs`, main took `0065` first,
and the branch's step lands as `0066_add_refs` with `supersedes: ["0065_add_refs"]`.

### Squash on merge

A branch that applied `0091_x` and then needed `0092_fix_x` merges **one** migration: `0091_x`
rewritten to the final shape, at the next revision, superseding the chain.

```swift
MigrationStep(
    identifier: "0091_x",
    sourceFile: "M0091_X.swift",
    revision: 2,
    supersedes: ["0091_x@1", "0092_fix_x"],
    apply: { db in /* the final shape, from the schema before 0091_x */ },
    rollback: { db in /* undo the final shape */ }
)
```

Databases that ran the chain count as current; fresh databases run the single step and record it
at revision 2. Keep the chain's old definitions in your tests and prove the squash
matches them:

```swift
let report = try SquashEquivalence.compare(
    base: { db in /* the schema before the chain, e.g. migrate a queue up to 0090 */ },
    chain: [m0091XRevision1, m0092FixX],
    squashed: .m0091X,
    fixture: { db in /* rows for a data-migrating step; row counts are then compared */ }
)
XCTAssertTrue(report.isEquivalent, report.description)
```

`compare` applies each side to its own in-memory database and compares tables, columns (type,
`NOT NULL`, default, primary key, hidden), foreign keys, indexes (columns, order, collation,
uniqueness, partial `WHERE`), each table's `CREATE TABLE` text (normalized, with its column and
constraint list sorted: this is where `CHECK` constraints live), triggers and views (normalized
SQL), and with a fixture, row counts. Column order is not compared. A squash that does not match
fails the test, never a database.

## API Overview

Core (`MigrationKit`):

| Type | What it does |
|------|-------------|
| `MigrationStep<Database>` | Holds an identifier, source file, revision, superseded migrations, apply closure, and optional rollback closure |
| `MigrationReference` | An identifier with an optional revision (`"0091_x"`, `"0091_x@1"`) |
| `MigrationProvenance` | The commit and branch recorded with each ledger row |
| `LedgerDiff` | Steps behind, identifiers ahead, steps diverged, steps with an incomplete superseded chain |
| `MigrationRegistry<Database>` | Validates ordering and uniqueness; exposes the manifest and rollback-capable identifiers |
| `MigrationHostIntegration` | Optional hooks for schema bootstrap, integrity checks, post-migration verification, and bookkeeping inside a rollback's transaction |
| `RollbackTarget` / `RollbackReport` | Which applied steps a rollback reverses; the tables and columns it takes away, with their counts |
| `SchemaSnapshotProvider` | Protocol for generating a canonical schema snapshot |

GRDB (`MigrationKitGRDB`):

| Type | What it does |
|------|-------------|
| `GRDBMigrationRunner` | Migrate forward, roll back, query status and pending steps, reconcile and diff the ledger |
| `SquashEquivalence` | Compares the schema a squashed step leaves with the chain it supersedes |
| `GRDBMigrationVerifier` | SQLite `quick_check`, foreign key validation, required index checks |

Errors:

| Error | When it's thrown |
|-------|-----------------|
| `MigrationKitError.duplicateIdentifiers` | Two steps share the same identifier |
| `MigrationKitError.identifiersOutOfOrder` | Steps aren't in lexicographic order |
| `MigrationKitError.rollbackNotDefined` | Rollback requested on a step that doesn't have one |
| `MigrationKitError.rollbackBlockedByUnknownMigrations` | A migration this build doesn't know was applied after the steps to reverse |
| `MigrationKitError.rollbackPlanChanged` | The steps a rollback would reverse are no longer the ones `expecting:` names |
| `MigrationKitError.invalidSupersession` | A `supersedes` reference is registered, named twice, malformed, or names its own step at its own revision |
| `MigrationKitError.supersededChainIncomplete` | The database applied only part of what a step supersedes |
| `GRDBMigrationVerificationError.quickCheckFailed` | SQLite integrity check fails |
| `GRDBMigrationVerificationError.foreignKeyViolations` | Foreign key violations found |

## Versioning

[Semantic Versioning](https://semver.org). Tags use the `v` prefix (e.g. `v0.2.0`). See [CHANGELOG.md](CHANGELOG.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT. See [LICENSE](LICENSE).
