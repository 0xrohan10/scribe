#!/usr/bin/env bash
# Tag HEAD with the next semver version. Builds read their version from this tag (see scripts/stamp-version.sh).
#
# Usage: scripts/bump.sh patch|minor|major
set -euo pipefail

cd "$(dirname "$0")/.."
PART="${1:-}"
case "$PART" in patch | minor | major) ;; *) echo "Usage: $0 patch|minor|major" >&2; exit 1 ;; esac

git diff --quiet HEAD || { echo "✗ Commit your changes first, so the tag matches what's built." >&2; exit 1; }

LATEST=$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' 2>/dev/null || echo v0.0.0)
IFS=. read -r MAJOR MINOR PATCH <<<"${LATEST#v}"
case "$PART" in
    patch) PATCH=$((PATCH + 1)) ;;
    minor) MINOR=$((MINOR + 1)) PATCH=0 ;;
    major) MAJOR=$((MAJOR + 1)) MINOR=0 PATCH=0 ;;
esac
NEXT="v$MAJOR.$MINOR.$PATCH"

git tag -a "$NEXT" -m "$NEXT"
echo "Tagged $(git rev-parse --short HEAD) as $NEXT (was $LATEST). Push it with: git push origin $NEXT"
