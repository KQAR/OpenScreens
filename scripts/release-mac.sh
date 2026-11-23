#!/bin/sh
# Builds the Mac app for release: archive, sign with Developer ID, have Apple
# notarise it, staple the ticket and wrap the result in a disk image.
#
#   scripts/release-mac.sh [output directory]
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
set -eu

OUT="${1:-dist}"
. "$(dirname "$0")/lib/api-key.sh"
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

TEAM=$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' Config/Signing.xcconfig | head -1)
[ -n "$TEAM" ] || { echo "Set DEVELOPMENT_TEAM in Config/Signing.xcconfig first." >&2; exit 1; }
VERSION=$(sed -n 's/^MARKETING_VERSION *= *//p' Config/Base.xcconfig)

echo "Archiving OpenScreens ${VERSION}..."
xcodebuild archive \
    -project OpenScreens.xcodeproj -scheme OpenScreens -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "$WORK/OpenScreens.xcarchive" \
    -allowProvisioningUpdates "$@" -quiet

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
(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")

echo "Done: $DMG"
cat "$DMG.sha256"
