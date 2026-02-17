# Changelog
All notable changes to this project will be documented in this file.

This project follows Semantic Versioning.

## [Unreleased]
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
