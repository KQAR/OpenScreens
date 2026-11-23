#!/bin/sh
# Publishes a Mac release made by scripts/release-mac.sh on GitHub.
#
#   scripts/publish-mac.sh [output directory] [release notes file]
#
# A release carries three files: the disk image, its checksum and the update
# feed. Copies of the app that are already installed look for the feed on
# the newest release, so a release without one is a release they are not
# told about, and this script will not make one.
#
# The release notes default to what CHANGELOG.md says about the version.
set -eu

OUT="${1:-dist}"
cd "$(dirname "$0")/.."
VERSION=$(sed -n 's/^MARKETING_VERSION *= *//p' Config/Base.xcconfig)
DMG="$OUT/OpenScreens-$VERSION.dmg"

for file in "$DMG" "$DMG.sha256" "$OUT/appcast.xml"; do
    [ -f "$file" ] || { echo "Missing $file. Run scripts/release-mac.sh first." >&2; exit 1; }
done
# The feed has to be about this version and point at where this release's
# disk image will be.
grep -q "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" "$OUT/appcast.xml" || {
    echo "$OUT/appcast.xml is not about version $VERSION." >&2
    exit 1
}
grep -q "releases/download/v$VERSION/OpenScreens-$VERSION.dmg" "$OUT/appcast.xml" || {
    echo "$OUT/appcast.xml does not point at this release's disk image." >&2
    exit 1
}

NOTES="${2:-}"
if [ -z "$NOTES" ]; then
    NOTES="$(mktemp)"
    trap 'rm -f "$NOTES"' EXIT
    awk -v version="$VERSION" '
        /^## / { printing = ($2 == version); next }
        printing { print }
    ' CHANGELOG.md | sed -e '/./,$!d' > "$NOTES"
    [ -s "$NOTES" ] || { echo "CHANGELOG.md says nothing about $VERSION." >&2; exit 1; }
fi

gh release create "v$VERSION" --target "$(git rev-parse HEAD)" \
    --title "OpenScreens $VERSION" --notes-file "$NOTES" \
    "$DMG" "$DMG.sha256" "$OUT/appcast.xml"
