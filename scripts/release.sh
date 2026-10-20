#!/bin/sh
# Cuts a release: tags the current commit and pushes it; GitHub Actions builds and publishes it.
# Usage: scripts/release.sh 1.2.0 "- What changed
# - Another change"
set -e
cd "$(dirname "$0")/.."

VERSION="$1"
NOTES="$2"
if [ -z "$VERSION" ] || [ -z "$NOTES" ]; then
	echo "usage: $0 <version, e.g. 1.2.0> \"<release notes>\""
	exit 1
fi
echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "Version must look like 1.2.0"; exit 1; }
git diff --quiet && git diff --cached --quiet || { echo "Commit or stash your changes first."; exit 1; }
git rev-parse "v$VERSION" >/dev/null 2>&1 && { echo "v$VERSION already exists."; exit 1; }

git tag -a "v$VERSION" -m "$NOTES"
git push origin HEAD "v$VERSION"
echo "Pushed v$VERSION. GitHub Actions is building it:"
echo "  https://github.com/rustyhammers/nas-mover/actions"
echo "Installed copies will offer the update once the release appears."
