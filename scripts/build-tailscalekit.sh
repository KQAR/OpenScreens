#!/bin/sh
# Builds TailscaleKit.xcframework (iPhone and iPad, device and simulator) from
# a pinned libtailscale commit and zips it for a GitHub release, printing the
# checksum Package.swift wants for its binaryTarget.
#
# Needs Xcode and the Go toolchain named in libtailscale's go.mod.
#
#   scripts/build-tailscalekit.sh            # -> dist/TailscaleKit.xcframework.zip
#
# Then upload the zip to a release of this repository and update the url and
# checksum of the TailscaleKit binaryTarget in Packages/OpenScreensKit.
set -eu

LIBTAILSCALE_COMMIT=dacde75057ff350e146505829beff446e6823966

root=$(cd "$(dirname "$0")/.." && pwd)
work="$root/build/libtailscale"
out="$root/dist"

rm -rf "$work"
git clone --quiet https://github.com/tailscale/libtailscale.git "$work"
git -C "$work" checkout --quiet "$LIBTAILSCALE_COMMIT"

make -C "$work/swift" ios ios-sim

products="$work/swift/build/Build/Products"
mkdir -p "$out"
rm -rf "$out/TailscaleKit.xcframework" "$out/TailscaleKit.xcframework.zip"
xcodebuild -create-xcframework \
    -framework "$products/Release-iphoneos/TailscaleKit.framework" \
    -framework "$products/Release-iphonesimulator/TailscaleKit.framework" \
    -output "$out/TailscaleKit.xcframework"
(cd "$out" && ditto -c -k --keepParent TailscaleKit.xcframework TailscaleKit.xcframework.zip)

echo "libtailscale $LIBTAILSCALE_COMMIT"
echo "checksum: $(swift package compute-checksum "$out/TailscaleKit.xcframework.zip")"
