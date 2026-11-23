#!/bin/sh
# Builds the Mac app for release: archive, sign with Developer ID, have Apple
# notarise it, staple the ticket, wrap the result in a disk image, and write
# the feed that tells copies of the app already out there about it.
#
#   SPARKLE_KEY=/path/to/the/update/signing/key scripts/release-mac.sh [output directory]
#
# What it leaves in the output directory is what a release on GitHub has to
# carry: the disk image, its checksum and appcast.xml. scripts/publish-mac.sh
# publishes them.
#
# The app updates itself with Sparkle. An update is accepted only if it is
# signed with the key whose public half is SUPublicEDKey in the app's
# Info.plist, and so is the feed. SPARKLE_KEY names the file with the
# private half: 32 random bytes in base64, as Sparkle's generate_keys -x
# writes it. Without that file no copy of the app will take an update, so
# it is to be kept, and kept to yourself.
#
# Signing and notarisation go through the Apple ID that Xcode is signed in
# with, for the team in Config/Signing.xcconfig. Nothing is uploaded anywhere
# but Apple's notary service; publishing the disk image is a separate step.
#
# An App Store Connect API key can stand in for the Apple ID:
#
#   APP_STORE_CONNECT_KEY=/path/to/AuthKey_<key id>.p8 \
#   APP_STORE_CONNECT_ISSUER=<issuer id> scripts/release-mac.sh
#
# A Developer ID certificate is the account holder's to hand out. Xcode signs
# with one for a key only if the key has been given access to cloud-managed
# distribution certificates; otherwise the export stops with a cloud signing
# permission error.
#
# A key without that access can still make a release where the certificate
# is in the keychain. Name a Developer ID provisioning profile that is
# installed here and includes it:
#
#   DEVELOPER_ID_PROFILE="OpenScreens Developer ID" \
#   APP_STORE_CONNECT_KEY=... APP_STORE_CONNECT_ISSUER=... scripts/release-mac.sh
#
# The app is then signed with the certificate on this Mac and sent to the
# notary service with notarytool, and the key is asked for nothing else.
# So is the disk image, which is then one macOS knows before it is opened,
# and one a copy of the app would take from this developer even if the
# update key were lost.
#
# OPENSCREENS_VERSION and OPENSCREENS_BUILD build the same source under
# another version's number. That is for scripts/update-trial.sh, which
# wants an older build to update from, and there was none that could when
# updating was new. A release sets neither.
set -eu

OUT="${1:-dist}"
. "$(dirname "$0")/lib/api-key.sh"
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

TEAM=$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' Config/Signing.xcconfig | head -1)
[ -n "$TEAM" ] || { echo "Set DEVELOPMENT_TEAM in Config/Signing.xcconfig first." >&2; exit 1; }
VERSION=${OPENSCREENS_VERSION:-$(sed -n 's/^MARKETING_VERSION *= *//p' Config/Base.xcconfig)}
BUILD=${OPENSCREENS_BUILD:-$(sed -n 's/^CURRENT_PROJECT_VERSION *= *//p' Config/Base.xcconfig)}
# Where the disk image will be downloaded from, which the feed has to say.
DOWNLOADS=https://github.com/burakgon/OpenScreens/releases/download/v$VERSION/

[ -n "${SPARKLE_KEY:-}" ] && [ -r "$SPARKLE_KEY" ] || {
    echo "Set SPARKLE_KEY to the file with the key updates are signed with." >&2
    exit 1
}
# What the app shows as new after an update is its own copy of the change
# log, and what the feed says about this release is this release's part of
# it. Neither may be out of date.
cmp -s CHANGELOG.md Packages/OpenScreensKit/Sources/OpenScreensUI/Resources/CHANGELOG.md || {
    echo "The change log in the app is not the one at the top. Run scripts/sync-changelog.sh." >&2
    exit 1
}
NOTES="$WORK/notes.md"
awk -v version="$VERSION" '
    /^## / { printing = ($2 == version); next }
    printing { print }
' CHANGELOG.md | sed -e '/./,$!d' > "$NOTES"
[ -s "$NOTES" ] || { echo "CHANGELOG.md says nothing about $VERSION." >&2; exit 1; }

echo "Archiving OpenScreens ${VERSION} (${BUILD})..."
# The packages are fetched into the work folder, which is also where
# Sparkle's own tools for signing a release come from.
xcodebuild archive \
    -project OpenScreens.xcodeproj -scheme OpenScreens -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "$WORK/OpenScreens.xcarchive" \
    -clonedSourcePackagesDirPath "$WORK/packages" \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
    -allowProvisioningUpdates "$@" -quiet
SPARKLE_TOOLS="$WORK/packages/artifacts/sparkle/Sparkle/bin"
[ -x "$SPARKLE_TOOLS/generate_appcast" ] || {
    echo "Sparkle's tools were not where they were expected: $SPARKLE_TOOLS" >&2
    exit 1
}

if [ -n "${DEVELOPER_ID_PROFILE:-}" ]; then
    [ -n "${APP_STORE_CONNECT_KEY:-}" ] || {
        echo "DEVELOPER_ID_PROFILE needs APP_STORE_CONNECT_KEY as well, for the notary service." >&2
        exit 1
    }
    BUNDLE_ID=$(/usr/libexec/PlistBuddy \
        -c "Print :ApplicationProperties:CFBundleIdentifier" "$WORK/OpenScreens.xcarchive/Info.plist")
    cat > "$WORK/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>destination</key><string>export</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>Developer ID Application</string>
    <key>teamID</key><string>$TEAM</string>
    <key>provisioningProfiles</key>
    <dict>
        <key>$BUNDLE_ID</key><string>$DEVELOPER_ID_PROFILE</string>
    </dict>
</dict>
</plist>
PLIST

    echo "Signing with the Developer ID certificate in the keychain..."
    xcodebuild -exportArchive \
        -archivePath "$WORK/OpenScreens.xcarchive" \
        -exportOptionsPlist "$WORK/export.plist" -exportPath "$WORK/notarized"
    APP="$WORK/notarized/OpenScreens.app"

    echo "Sending to Apple's notary service..."
    ditto -c -k --keepParent "$APP" "$WORK/OpenScreens.zip"
    xcrun notarytool submit "$WORK/OpenScreens.zip" \
        --key "$key_path" --key-id "${key_id#AuthKey_}" --issuer "$APP_STORE_CONNECT_ISSUER" \
        --wait | tee "$WORK/notary.log"
    grep -q "status: Accepted" "$WORK/notary.log" || {
        echo "The notary service did not accept the app." >&2
        exit 1
    }
    xcrun stapler staple "$APP"
else

cat > "$WORK/upload.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>destination</key><string>upload</string>
    <key>signingStyle</key><string>automatic</string>
    <key>teamID</key><string>$TEAM</string>
</dict>
</plist>
PLIST

echo "Sending to Apple's notary service..."
xcodebuild -exportArchive \
    -archivePath "$WORK/OpenScreens.xcarchive" \
    -exportOptionsPlist "$WORK/upload.plist" -exportPath "$WORK/upload" \
    -allowProvisioningUpdates "$@"

echo "Waiting for the notarised app..."
tries=0
until xcodebuild -exportNotarizedApp \
        -archivePath "$WORK/OpenScreens.xcarchive" -exportPath "$WORK/notarized" \
        -allowProvisioningUpdates "$@" >"$WORK/notarized.log" 2>&1; do
    tries=$((tries + 1))
    if [ "$tries" -ge 60 ]; then
        cat "$WORK/notarized.log" >&2
        echo "Notarisation did not finish in half an hour." >&2
        exit 1
    fi
    sleep 30
done

APP="$WORK/notarized/OpenScreens.app"

fi

xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

echo "Building the disk image..."
mkdir -p "$OUT" "$WORK/dmg"
cp -R "$APP" "$WORK/dmg/"
ln -s /Applications "$WORK/dmg/Applications"
DMG="$OUT/OpenScreens-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "OpenScreens" -srcfolder "$WORK/dmg" -fs APFS -format ULFO -quiet "$DMG"

if [ -n "${DEVELOPER_ID_PROFILE:-}" ]; then
    # The disk image is what is downloaded, so it is signed and notarised
    # as well, and carries its own ticket: a Mac that is offline can then
    # tell what it is before anything in it is opened.
    IDENTITY=$(security find-identity -v -p codesigning \
        | awk -v team="($TEAM)" '/Developer ID Application/ && index($0, team) { print $2; exit }')
    [ -n "$IDENTITY" ] || { echo "No Developer ID Application certificate for the team is in the keychain." >&2; exit 1; }
    echo "Signing and notarising the disk image..."
    codesign --sign "$IDENTITY" --timestamp "$DMG"
    xcrun notarytool submit "$DMG" \
        --key "$key_path" --key-id "${key_id#AuthKey_}" --issuer "$APP_STORE_CONNECT_ISSUER" \
        --wait | tee "$WORK/notary-dmg.log"
    grep -q "status: Accepted" "$WORK/notary-dmg.log" || {
        echo "The notary service did not accept the disk image." >&2
        exit 1
    }
    xcrun stapler staple "$DMG"
fi

# Everything below is about the file as it now is: the checksum, and the
# signature the update feed carries for it.
(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")

echo "Writing the update feed..."
# The feed is made from a folder holding the disk image and, beside it and
# under the same name, what to say about it.
mkdir -p "$WORK/feed"
cp "$DMG" "$WORK/feed/"
cp "$NOTES" "$WORK/feed/OpenScreens-$VERSION.md"
rm -f "$OUT/appcast.xml"
"$SPARKLE_TOOLS/generate_appcast" \
    --ed-key-file "$SPARKLE_KEY" \
    --download-url-prefix "$DOWNLOADS" \
    --embed-release-notes \
    --link "https://github.com/burakgon/OpenScreens" \
    -o "$OUT/appcast.xml" "$WORK/feed" >/dev/null
# A feed without a signature on the download, or without one on itself, is
# one no copy of the app will act on, and it would say nothing of why.
grep -q 'sparkle:edSignature="' "$OUT/appcast.xml" || {
    echo "The update was not signed. Is SPARKLE_KEY the key the app was built to trust?" >&2
    exit 1
}
"$SPARKLE_TOOLS/sign_update" --verify --ed-key-file "$SPARKLE_KEY" "$OUT/appcast.xml" >/dev/null || {
    echo "The update feed was not signed." >&2
    exit 1
}

echo "Done: $DMG"
cat "$DMG.sha256"
echo "The update feed: $OUT/appcast.xml"
