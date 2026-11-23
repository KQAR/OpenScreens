#!/bin/sh
# Copies the change log into the app, which shows what is new from it after
# an update. Run this after editing CHANGELOG.md; a test fails until it is.
set -eu
cd "$(dirname "$0")/.."
cp CHANGELOG.md Packages/OpenScreensKit/Sources/OpenScreensUI/Resources/CHANGELOG.md
echo "Copied CHANGELOG.md into the app's resources."
