# Contributing
## Setup
1. Install Swift 6.2+.
2. Clone the repository.
3. Run:
   - `swift build --build-tests`
   - `swift test`

## Development workflow
1. Create a feature branch from `main`.
2. Keep changes scoped and tests updated.
3. Open a pull request with a clear summary and rationale.

## Versioning
- Use Semantic Versioning for releases.
- Keep breaking API changes for major versions.
- Update `CHANGELOG.md` as part of each release.

## Release tags
- Release tags must use `vMAJOR.MINOR.PATCH` format.
- Use `scripts/release.sh` to validate and push tags.
