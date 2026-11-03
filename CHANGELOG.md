# Changelog
All notable changes to this project will be documented in this file.

This project follows Semantic Versioning.

## [Unreleased]
### Added
- `rollback(_:in:)` with `RollbackTarget.steps(_:)` and `.to(_:)`: every step reverses in one transaction.
- `rollbackReport(_:in:)`: the tables and columns a rollback takes away, with their row and value
  counts, measured in a savepoint that is undone.
- `MigrationHostIntegration.didRollback`, which runs inside the rollback's transaction.
- CLI `rollback --to <identifier>` and `--dry-run`; the command prints what goes before it changes
  anything, and `MigrationCLIHost.prepareRollback` runs between the two.
- `MigrationKitError.rollbackBlockedByUnknownMigrations`, thrown when this build would reverse
  migrations that a newer, unknown migration was applied after. Unknown identifiers are placed by
  string order only when the registry enforces lexicographic order; otherwise any one refuses.
- `rollback(_:in:expecting:)` and `MigrationKitError.rollbackPlanChanged`: the CLI passes the
  identifiers it reported, so a rollback another writer changed since is refused, not run.

### Changed
- `rollbackLastMigration`, `rollbackMigrations(in:steps:)` and `rollbackMigration(identifier:in:)`
  run through the same transaction: a failing step now leaves every step applied, instead of the
  ones before it reversed. Their steps are chosen and checked inside it, before any runs.
- Post-rollback verification runs once per rollback (the host's `verifyPostMigration`, or the
  integrity check without one), as after `migrate`, instead of an integrity check plus the host's
  checks after every step.
- A failed rollback clears the connection's GRDB schema cache, which does not learn of `ROLLBACK`.

## [0.2.0] - 2026-02-17
### Added
- Ported full multi-product migration toolkit from Kapsicum local package.
- Added `MigrationKitGRDB` and `MigrationKitCLI` library products.
- Added `migrationkit-cli` executable product.
- Added GRDB-backed migration runner/helpers/verifier and CLI command host.
- Added registry and GRDB integration tests.
## [0.1.1] - 2026-02-17
### Fixed
- Lowered Swift tools version requirement to 6.1 for GitHub Actions `macos-latest` compatibility.
- Updated package installation docs to reference `0.1.1`.

## [0.1.0] - 2026-02-17
### Added
- Initial `MigrationKit` package scaffold.
- `SemanticVersion` parsing and ordering support.
- `MigrationStep` and `MigrationRunner` core APIs.
- Migration reporting with applied step IDs and final version.
- Unit tests for version parsing, range handling, and duplicate detection.
- CI workflow for pull requests and `main` pushes.
- Release workflow for semver tags (`v*`).

[Unreleased]: https://github.com/llk23r/kapsicum-migration-kit/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/llk23r/kapsicum-migration-kit/releases/tag/v0.2.0
[0.1.1]: https://github.com/llk23r/kapsicum-migration-kit/releases/tag/v0.1.1
[0.1.0]: https://github.com/llk23r/kapsicum-migration-kit/releases/tag/v0.1.0
