# Contributing to `MigrationKit`

## Setup

1. Install Swift 6.1+ (ships with Xcode 16.3+, or via [swiftly](https://github.com/swiftlang/swiftly)).
2. Clone the repository.
3. Build and test:

```bash
swift build --build-tests
swift test
```

## Development Workflow

1. Create a feature branch from `main`.
2. Keep changes scoped and tests updated.
3. Open a pull request with a clear summary and rationale.

## Releasing

Releases are created via `scripts/release.sh`:

```bash
scripts/release.sh v0.2.0
```

The script validates the semver format, ensures a clean working tree, runs build + test, creates an annotated tag, and pushes. GitHub Actions then publishes a GitHub Release automatically.

Update `CHANGELOG.md` before tagging.

## Formatting

Source files are formatted with `swift-format` using the config in `.swift-format`. CI checks this on every PR.

To format locally:

```bash
swift format --in-place --recursive Sources/ Tests/
```

## Conventions

- Swift language mode v6 (strict concurrency).
- Swift Testing (`@Test`, `#expect()`), not XCTest.
- [Semantic Versioning](https://semver.org). Tags use `v` prefix.
- Migration identifiers: lexicographically ordered, `NNNN_snake_case`.
