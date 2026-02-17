# How MigrationKit Works

You ship a new version of your app. A user opens it. Their database was created six months ago; it has tables and columns your new code no longer expects. Something needs to quietly reshape that data before the first screen appears.

That something is a migration. This document traces what actually happens inside MigrationKit when a migration runs, from the moment your app hands it a list of steps to the moment it hands back a verified database.

## The Map

```
  You define steps
       │
       ▼
 ┌─────────────┐
 │  Registry    │ ← validates ordering, catches duplicates
 └─────┬───────┘
       │
       ▼
 ┌─────────────┐
 │   Runner     │ ← checks what's already applied
 └─────┬───────┘
       │
       ▼
 ┌─────────────┐
 │  Migration   │ ← each step's closure runs against the database
 │  Execution   │
 └─────┬───────┘
       │
       ▼
 ┌─────────────┐
 │ Verification │ ← integrity check, foreign keys, required indexes
 └─────┬───────┘
       │
       ▼
  Database is ready
```

---

## Baseline Vocabulary

These terms are assumed known throughout: *app, database, table, column, function, closure, string, array, error, version, file, order, identifier*.

---

## Q1: What is a migration step?

Your database changes over time. Each change gets a name and a function that performs it. In MigrationKit, that pair is a `MigrationStep`.

```swift
MigrationStep<Database>(
    identifier: "0001_create_items",
    sourceFile: "M0001_CreateItems.swift",
    apply: { db in
        try db.create(table: "items") { t in
            t.column("id", .integer).primaryKey()
        }
    },
    rollback: { db in
        try db.drop(table: "items")
    }
)
```

The `identifier` is a string that names this step uniquely. The `sourceFile` records which file defines it; this is bookkeeping for humans, not something MigrationKit executes. The `apply` closure does the actual work. The `rollback` closure undoes it; it is optional.

Notice the `<Database>` in `MigrationStep<Database>`. The step is *generic*. MigrationKit's core module has no opinion about what `Database` actually is. It could be a GRDB `Database`, a plain dictionary, or anything else. The core module just carries these closures around; the runner is what eventually calls them.

**Vocabulary Introduced:**

| Term | Meaning |
|------|---------|
| `MigrationStep` | A named pair: an identifier and a closure that transforms a database |
| generic | A type that works with different concrete types; here, `Database` is a placeholder |
| `apply` | The closure that performs the migration |
| `rollback` | The optional closure that undoes it |

**Where We Are:**

```
  You define steps  ← here
       │
       ▼
    Registry
```

---

## Q2: How does the registry catch mistakes before anything runs?

You have a list of steps. Before any of them touch a database, MigrationKit checks two things: are all identifiers unique, and are they in the right order?

This is what `MigrationRegistry` does. When you create one, it immediately scans the identifier list:

```swift
let registry = try MigrationRegistry(steps: steps)
```

**Duplicate detection.** It groups identifiers by value and checks if any appear more than once. If `"0001_create_items"` shows up twice, it throws `MigrationKitError.duplicateIdentifiers(["0001_create_items"])` before anything else happens.

**Order enforcement.** It sorts the identifiers lexicographically (dictionary order) and compares that sorted list to the list you provided. If they differ, it throws `identifiersOutOfOrder` with both lists so you can see exactly what is wrong. This is why the `0001_`, `0002_` prefix convention matters; it makes lexicographic order match chronological order.

You can opt out of order enforcement by passing `enforceLexicographicOrder: false`. But the default is strict, and for good reason: if step 2 assumes step 1 already ran, and someone accidentally reorders them, the database ends up in a state neither step expected.

The registry does not touch the database. It does not run closures. It only looks at identifiers and decides whether the list is safe to use.

**How We Know:**

The validation logic lives in `MigrationRegistry.init` (`Sources/MigrationKit/MigrationRegistry.swift`). It uses `Dictionary(grouping:by:)` for duplicate detection and a simple `sorted() != identifiers` comparison for order checking.

**Failure Modes:**

| Failure | Cause | Error |
|---------|-------|-------|
| Duplicate identifier | Copy-paste mistake or merge conflict | `duplicateIdentifiers([...])` |
| Wrong order | New step inserted in the middle instead of appended | `identifiersOutOfOrder(expected:actual:)` |

**Vocabulary Introduced:**

| Term | Meaning |
|------|---------|
| `MigrationRegistry` | Validates a list of steps for uniqueness and ordering before execution |
| lexicographic order | Dictionary order; `"0001_a"` comes before `"0002_b"` because `"0"` < `"0"` then `"0"` < `"2"` |

**Where We Are:**

```
  You define steps
       │
       ▼
    Registry  ← here
       │
       ▼
     Runner
```

---

## Q3: What does the runner do that the registry does not?

The registry validates your list. The runner uses it against a real database.

`GRDBMigrationRunner` wraps a registry and provides the full lifecycle: migrate forward, check status, roll back. When you create a runner, it creates a registry internally, so you get all the validation from Q2 for free.

```swift
let runner = try GRDBMigrationRunner(steps: steps)
```

When you call `runner.migrate(in: writer)`, three things happen in sequence:

1. **Build a GRDB migrator.** The runner iterates over the registry's steps and registers each one with GRDB's own `DatabaseMigrator`. GRDB tracks which identifiers have already been applied in an internal table called `grdb_migrations`. When the migrator runs, it skips identifiers already present in that table and applies the rest.

2. **Apply pending steps.** For each unapplied step, the `apply` closure runs inside a database transaction. If it throws, the transaction rolls back and the error propagates. If it succeeds, GRDB records the identifier in `grdb_migrations`.

3. **Verify.** After all steps complete, the runner runs post-migration checks. More on this in Q5.

So the registry is a compile-time guard (is this list well-formed?), and the runner is a runtime engine (what needs to happen to this database right now?).

**How We Know:**

The `buildMigrator()` method in `GRDBMigrationRunner` (`Sources/MigrationKitGRDB/GRDBMigrationRunner.swift`) loops over `registry.steps` and calls `migrator.registerMigration` for each. GRDB's `DatabaseMigrator.migrate` handles the applied-check and transaction semantics.

**Vocabulary Introduced:**

| Term | Meaning |
|------|---------|
| `GRDBMigrationRunner` | Orchestrates the full migration lifecycle against a GRDB database |
| `grdb_migrations` | A table GRDB maintains internally to track which migration identifiers have been applied |
| transaction | A database operation that either fully succeeds or fully reverts; no halfway states |

**Where We Are:**

```
    Registry
       │
       ▼
     Runner  ← here
       │
       ▼
   Execution
```

---

## Q4: How does rollback work?

Forward migration adds structure. Rollback removes it. But MigrationKit only allows rolling back the *most recently applied* migration. You cannot skip ahead and undo step 3 while step 4 is still applied; that would leave the database in an impossible state.

When you call `runner.rollbackLastMigration(in: writer)`, the runner:

1. Reads `grdb_migrations` to find which identifiers are applied.
2. Finds the latest applied identifier by walking the registry's list in reverse and picking the first match.
3. Checks that the step has a `rollback` closure. If it does not, it throws `rollbackNotDefined`.
4. Runs the rollback closure inside a write transaction.
5. Deletes that identifier's row from `grdb_migrations`.
6. Runs verification.

You can also rollback multiple steps at once with `rollbackMigrations(in:steps:)`. It simply repeats the single-step rollback N times, rechecking the latest applied identifier each time.

This is why rollback closures are optional. Not every migration is safely reversible. Dropping a column destroys data; you cannot un-drop it. MigrationKit makes you opt in to rollback per step, and throws a clear error if someone tries to roll back a step that never declared how.

**Failure Modes:**

| Failure | Cause | Error |
|---------|-------|-------|
| No rollback closure | Step was defined without one | `rollbackNotDefined("0002_...")` |
| Wrong target | Trying to rollback a step that is not the latest applied | `rollbackMustTargetLatestApplied(latestApplied:requested:)` |
| Negative step count | Passing a negative number to `rollbackMigrations` | `rollbackStepCountMustBeNonNegative` |

**Vocabulary Introduced:**

| Term | Meaning |
|------|---------|
| latest applied | The most recently applied migration, determined by position in the registry's ordered list |

**Where We Are:**

```
     Runner
       │
       ▼
   Execution  ← here (rollback is execution in reverse)
       │
       ▼
   Verification
```

---

## Q5: What does verification actually check?

After every migration or rollback, the runner asks: is this database still structurally sound?

`GRDBMigrationVerifier` runs two checks by default:

**1. SQLite quick_check.** This is a built-in SQLite command (`PRAGMA quick_check(1)`) that scans the database for corruption: broken B-tree pages, malformed records, encoding errors. It returns `"ok"` or a description of what is wrong. If it does not return `"ok"`, the verifier throws `quickCheckFailed`.

**2. Foreign key validation.** `PRAGMA foreign_key_check` finds rows that reference non-existent parent rows. If a migration accidentally deleted a parent table without cleaning up references, this catches it. The verifier throws `foreignKeyViolations(count:)` with the number of violations.

You can also verify required indexes by passing a list of `RequiredIndexSpec` values. The verifier queries `sqlite_master` to confirm each expected index exists on its expected table.

All of this is optional to override. `MigrationHostIntegration` lets you supply your own `verifyIntegrity` and `verifyPostMigration` closures. If you do, the runner calls yours instead of the defaults. This is how an app with custom invariants (say, "table X must always have at least one row") can plug in its own checks without forking the library.

**How We Know:**

`GRDBMigrationVerifier` lives in `Sources/MigrationKitGRDB/GRDBMigrationVerifier.swift`. The SQLite pragmas are documented in the [SQLite Pragma Reference](https://www.sqlite.org/pragma.html).

**Failure Modes:**

| Failure | Cause | Error |
|---------|-------|-------|
| Corruption detected | Disk error, interrupted write, or bug in a migration | `quickCheckFailed(result:)` |
| Orphaned foreign keys | Migration deleted a parent row or table without cascading | `foreignKeyViolations(count:)` |
| Missing index | Migration forgot to create a required index | `missingIndex(table:index:)` |

**Vocabulary Introduced:**

| Term | Meaning |
|------|---------|
| `GRDBMigrationVerifier` | Runs structural health checks on the database after migrations |
| `quick_check` | A SQLite pragma that scans for internal corruption |
| `foreign_key_check` | A SQLite pragma that finds rows referencing non-existent parents |
| `RequiredIndexSpec` | A declaration that a specific index must exist on a specific table |
| `MigrationHostIntegration` | A struct of optional closures that let the host app override default behavior |

**Where We Are:**

```
   Execution
       │
       ▼
   Verification  ← here
       │
       ▼
  Database is ready
```

---

## Q6: How does the CLI tie it all together?

Everything above is library code; it runs inside your app process. The CLI layer puts a command-line interface on top of the same runner.

`MigrationCLIHost` bundles three things: a `GRDBMigrationRunner`, a function that opens a database writer given connection options, and an optional function that generates a schema snapshot. You wire these up and hand them to `MigrationCLI.run`.

The CLI exposes five commands:

| Command | What it does | Runner method called |
|---------|-------------|---------------------|
| `migrate` | Apply pending steps (optionally up to a target) | `migrate(in:)` or `migrate(in:upTo:)` |
| `status` | Print up/down for every registered step | `migrationStatus(in:)` |
| `rollback` | Undo the last N steps | `rollbackMigrations(in:steps:)` |
| `verify` | Run post-migration checks without migrating | `runPostMigrationChecks(in:)` |
| `schema-dump` | Write canonical schema SQL to a file | host's `generateSchemaSnapshot` closure |

Each command accepts `--db-path`, `--password`, `--keychain-service`, and `--keychain-account` options so you can point it at any database without hardcoding paths.

The `migrationkit-cli` executable target is a shell; it prints a message telling you to embed `MigrationCLI.run` in your own binary. The library gives you the engine. You provide the wiring.

**Vocabulary Introduced:**

| Term | Meaning |
|------|---------|
| `MigrationCLIHost` | A bundle of runner + database opener + optional schema snapshot generator |
| `MigrationCLI` | Entry point that parses arguments and dispatches to the right command |

**Where We Are:**

```
  CLI parses command
       │
       ▼
  Opens database ──► Runner ──► Execution ──► Verification ──► Done
```

---

## Summary

The complete journey, start to finish:

1. **You define steps** with identifiers, source files, apply closures, and optional rollback closures.
2. **The registry validates** that identifiers are unique and in lexicographic order.
3. **The runner checks** which steps are already applied by reading `grdb_migrations`.
4. **Pending steps execute** inside transactions, one at a time, in order.
5. **Verification runs** SQLite integrity and foreign key checks.
6. **The database is ready.** Your app launches with the right schema.

| Layer | What lives there |
|-------|-----------------|
| Your app | Step definitions, database opener, host integration hooks |
| `MigrationKit` | `MigrationStep`, `MigrationRegistry`, `MigrationHostIntegration`, errors |
| `MigrationKitGRDB` | `GRDBMigrationRunner`, `GRDBMigrationVerifier`, SQL helpers |
| `MigrationKitCLI` | `MigrationCLI`, `MigrationCLIHost`, ArgumentParser commands |
| GRDB | `DatabaseMigrator`, `grdb_migrations` table, transaction management |
| SQLite | `PRAGMA quick_check`, `PRAGMA foreign_key_check`, `sqlite_master` |

## Complete Vocabulary

| Term | Introduced in | Meaning |
|------|--------------|---------|
| `MigrationStep` | Q1 | A named pair: an identifier and a closure that transforms a database |
| generic | Q1 | A type that works with different concrete types |
| `apply` | Q1 | The closure that performs the migration |
| `rollback` | Q1 | The optional closure that undoes it |
| `MigrationRegistry` | Q2 | Validates a list of steps for uniqueness and ordering |
| lexicographic order | Q2 | Dictionary order for strings |
| `GRDBMigrationRunner` | Q3 | Orchestrates the full migration lifecycle |
| `grdb_migrations` | Q3 | GRDB's internal table tracking applied identifiers |
| transaction | Q3 | An all-or-nothing database operation |
| latest applied | Q4 | The most recently applied migration by registry position |
| `GRDBMigrationVerifier` | Q5 | Runs structural health checks after migrations |
| `quick_check` | Q5 | SQLite pragma that scans for corruption |
| `foreign_key_check` | Q5 | SQLite pragma that finds orphaned foreign key references |
| `RequiredIndexSpec` | Q5 | Declaration that an index must exist |
| `MigrationHostIntegration` | Q5 | Optional closures for custom bootstrap/verification behavior |
| `MigrationCLIHost` | Q6 | Bundle of runner + database opener + optional snapshot generator |
| `MigrationCLI` | Q6 | Entry point for command-line argument parsing and dispatch |
