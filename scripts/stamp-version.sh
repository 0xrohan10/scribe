#!/bin/sh
# Xcode build phase: stamps the version from git into the built Info.plist.
#
# The latest vX.Y.Z tag is the version. A commit after it builds as the next patch's prerelease, e.g. v0.2.0
# plus 3 commits is 0.2.1-dev.3. The build number is the commit count, so it rises with every commit.
#
#   CFBundleShortVersionString  X.Y.Z of the latest tag (macOS only accepts plain numbers here)
#   CFBundleVersion             commit count
#   ScribeVersion               full semver shown in Settings ▸ About
#   ScribeGitSHA                short commit SHA
set -eu

cd "$SRCROOT"
SHA=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 0)
# v1.2.3-4-gabc1234: tag, commits since it, SHA.
DESC=$(git describe --tags --long --match 'v[0-9]*.[0-9]*.[0-9]*' 2>/dev/null || echo v0.0.0-0-g)
set -- $(echo "$DESC" | sed -E 's/^v([0-9]+)\.([0-9]+)\.([0-9]+)-([0-9]+)-g.*$/\1 \2 \3 \4/')
MAJOR=$1 MINOR=$2 PATCH=$3 AHEAD=$4

if [ "$AHEAD" -eq 0 ]; then
    VERSION="$MAJOR.$MINOR.$PATCH"
else
    VERSION="$MAJOR.$MINOR.$((PATCH + 1))-dev.$AHEAD"
fi

PLIST="$TARGET_BUILD_DIR/$INFOPLIST_PATH"
set_key() {
    /usr/libexec/PlistBuddy -c "Set :$1 $2" "$PLIST" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :$1 string $2" "$PLIST"
}
set_key CFBundleShortVersionString "$MAJOR.$MINOR.$PATCH"
set_key CFBundleVersion "$BUILD"
set_key ScribeVersion "$VERSION"
set_key ScribeGitSHA "$SHA"
