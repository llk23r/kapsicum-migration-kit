#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-}"

if [[ -z "$VERSION" ]]; then
  echo "Usage: scripts/release.sh vMAJOR.MINOR.PATCH"
  exit 1
fi

if [[ ! "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Invalid tag format: $VERSION (expected vMAJOR.MINOR.PATCH)"
  exit 1
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Working tree must be clean before releasing."
  exit 1
fi

if git rev-parse "$VERSION" >/dev/null 2>&1; then
  echo "Tag already exists: $VERSION"
  exit 1
fi

swift build --build-tests
swift test

git tag -a "$VERSION" -m "Release $VERSION"
git push origin main --follow-tags

echo "Released $VERSION"
