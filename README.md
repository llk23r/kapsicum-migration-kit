# MigrationKit
A lightweight Swift Package for deterministic, versioned data migrations that can be reused across apps and services.

## Why this package exists
- Keep migration logic decoupled from app repositories (like Kapsicum) for reuse.
- Enforce semantic-versioned migration steps.
- Provide predictable migration execution for partial upgrades and rollback-safe planning.

## Installation (Swift Package Manager)
In your `Package.swift`:
```swift
.package(url: "https://github.com/llk23r/kapsicum-migration-kit.git", from: "0.1.1")
```

Then add the product dependency:
```swift
.product(name: "MigrationKit", package: "kapsicum-migration-kit")
```

## Quick start
```swift
import MigrationKit

let runner = try MigrationRunner<[String: Int]>(steps: [
    .init(id: "seed", version: "1.0.0") { state in
        state["count"] = 1
    },
    .init(id: "bump", version: "1.1.0") { state in
        state["count", default: 0] += 1
    }
])

let report = try runner.migrate([:], from: "0.0.0", to: "1.1.0")
print(report.state)          // ["count": 2]
print(report.appliedStepIDs) // ["seed", "bump"]
```

## Versioning and tags
- This repo follows Semantic Versioning.
- Git tags are prefixed with `v` (for example: `v0.1.0`).
- Consumers should depend on tags/releases for deterministic integration.

## Release process
1. Update `CHANGELOG.md`.
2. Run local checks:
   - `swift build --build-tests`
   - `swift test`
3. Create and push a tag:
   - `scripts/release.sh vX.Y.Z`
4. GitHub Actions validates the tag and publishes a GitHub Release.

## CI
- Pull requests and pushes to `main` run build + tests.
- Tag pushes (`v*`) run release validation and release publication.
