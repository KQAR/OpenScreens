#!/bin/bash
# Tries an update for real: a build of the Mac app finds a newer one, takes
# it, quits, is replaced and is opened again. Then it is offered three
# things it has to turn down: a feed with no signature, a feed changed after
# it was signed, and a download changed after it was signed.
#
#   scripts/update-trial.sh [--shown] <older disk image> <newer disk image>
#
# Both are disk images as scripts/release-mac.sh makes them, and the older
# has to be 1.3.0 or later: it is the older version that does the updating.
# Before a release, the older one is the release people have.
#
# Nothing of the app that is installed on this Mac is touched, which takes
# more than a folder of its own for the data:
#
# - Sparkle keeps what it knows in the app's preferences, and those are
#   found by bundle identifier wherever the process says its home is. So
#   the trial runs copies of both builds under another identifier.
# - The copies trust a key that is made here and thrown away, so that the
#   project's key never signs anything that is not a release.
# - Sparkle opens the new version through the system, which hands on
#   nothing of the environment the old one ran in. The copy of the newer
#   build therefore names its own, in its Info.plist.
# - An app under an identifier macOS has not seen is asked about the local
#   network the moment it looks for computers nearby, so that is off.
#
# A hidden app presents no sheet. With --shown the copy's window is on
# screen while it updates, behind the others, and the update's own sheet is
# up when Sparkle asks the app to quit, which an app with a sheet up
# ignores. That is the run to make before a release. The copy that Sparkle
# opens again is closed as soon as it appears, since it comes to the front.
#
# The copies are signed with the Developer ID certificate for the team in
# Config/Signing.xcconfig, which has to be in the keychain. Sparkle's tools
# come with the package: build it once first.
set -u

HOW=-j
if [ "${1:-}" = "--shown" ]; then HOW=""; shift; fi
[ $# -eq 2 ] || { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
OLDER=$1
NEWER=$2
for image in "$OLDER" "$NEWER"; do
    [ -r "$image" ] || { echo "Not found: $image" >&2; exit 2; }
done

REPO=$(cd "$(dirname "$0")/.." && pwd)
TOOLS="$REPO/Packages/OpenScreensKit/.build/artifacts/sparkle/Sparkle/bin"
[ -x "$TOOLS/generate_appcast" ] || {
    echo "Sparkle's tools are not there yet. Run: swift build --package-path Packages/OpenScreensKit" >&2
    exit 2
}
TEAM=$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' "$REPO/Config/Signing.xcconfig" | head -1)
IDENTITY=$(security find-identity -v -p codesigning \
    | awk -v team="($TEAM)" '/Developer ID Application/ && index($0, team) { print $2; exit }')
[ -n "$IDENTITY" ] || { echo "No Developer ID Application certificate for the team is in the keychain." >&2; exit 2; }

TRIAL=com.burakgon.openscreens.trial
ISOLATED=com.burakgon.openscreens.isolated
PORT=8765
if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then
    echo "Port $PORT is in use, and the trial serves its feed there." >&2
    exit 2
fi

WORK=$(cd "$(mktemp -d)" && pwd -P)
RUN="$WORK/run"
APP="$RUN/OpenScreens.app"
PROCESS="$APP/Contents/MacOS/OpenScreens"
SERVER=""
failures=0

# What the trial changes outside its own folder, to be put back.
was_nearby=$(defaults read "$ISOLATED" showsNearbyComputers 2>/dev/null || echo unset)
was_tailscale=$(defaults read "$ISOLATED" tailscaleEnabled 2>/dev/null || echo unset)
restore() { # <key> <what it was>
    case "$2" in
        unset) defaults delete "$ISOLATED" "$1" >/dev/null 2>&1 ;;
        *) defaults write "$ISOLATED" "$1" -bool "$([ "$2" = 1 ] && echo true || echo false)" ;;
    esac
}
tidy() {
    [ -n "$SERVER" ] && kill "$SERVER" 2>/dev/null
    pkill -f "$PROCESS" 2>/dev/null
    restore showsNearbyComputers "$was_nearby"
    restore tailscaleEnabled "$was_tailscale"
    defaults delete "$TRIAL" >/dev/null 2>&1
    rm -f "${HOME:?}/Library/Preferences/$TRIAL.plist"
    rm -rf "${HOME:?}/Library/Caches/$TRIAL" "${HOME:?}/Library/HTTPStorages/$TRIAL"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -u "$APP" "$WORK/older/OpenScreens.app" "$WORK/newer/OpenScreens.app" >/dev/null 2>&1
    rm -rf "${WORK:?}"
}
trap tidy EXIT
defaults write "$ISOLATED" showsNearbyComputers -bool false
defaults write "$ISOLATED" tailscaleEnabled -bool false

plist() { /usr/libexec/PlistBuddy -c "$2" "$1/Contents/Info.plist" 2>/dev/null; }
version() { echo "$(plist "$1" 'Print :CFBundleShortVersionString') ($(plist "$1" 'Print :CFBundleVersion'))"; }

# --- The copies ---------------------------------------------------------

mkdir -p "$WORK/mount" "$WORK/older" "$WORK/newer" "$WORK/image" "$WORK/valid"
take() { # <disk image> <folder>
    hdiutil attach "$1" -nobrowse -readonly -mountpoint "$WORK/mount" -quiet 2>/dev/null || return 1
    cp -R "$WORK/mount/OpenScreens.app" "$2/OpenScreens.app"
    hdiutil detach "$WORK/mount" -quiet
}
take "$OLDER" "$WORK/older" && take "$NEWER" "$WORK/newer" || { echo "A disk image could not be opened." >&2; exit 2; }
[ -n "$(plist "$WORK/older/OpenScreens.app" 'Print :SUFeedURL')" ] || {
    echo "The older build does not update itself: $(version "$WORK/older/OpenScreens.app")." >&2
    exit 2
}

cat > "$WORK/key.swift" <<'SWIFT'
import CryptoKit
import Foundation
// Writes a new Ed25519 seed where Sparkle's tools read one, and prints its public half.
let key = Curve25519.Signing.PrivateKey()
FileManager.default.createFile(
    atPath: CommandLine.arguments[1],
    contents: Data((key.rawRepresentation.base64EncodedString() + "\n").utf8),
    attributes: [.posixPermissions: 0o600])
print(key.publicKey.rawRepresentation.base64EncodedString())
SWIFT
PUBLIC=$(swift "$WORK/key.swift" "$WORK/trial.key") || { echo "The trial's key could not be made." >&2; exit 2; }

for copy in older newer; do
    plist "$WORK/$copy/OpenScreens.app" "Set :CFBundleIdentifier $TRIAL"
    plist "$WORK/$copy/OpenScreens.app" "Set :SUPublicEDKey $PUBLIC"
done
plist "$WORK/newer/OpenScreens.app" "Add :LSEnvironment dict"
plist "$WORK/newer/OpenScreens.app" "Add :LSEnvironment:CFFIXED_USER_HOME string $RUN/home"
plist "$WORK/newer/OpenScreens.app" "Add :LSEnvironment:OPENSCREENS_DATA_DIR string $RUN/data"
for copy in older newer; do
    # The profile is for the real identifier, and with it go the
    # entitlements that needed one. An isolated run uses neither.
    rm -f "$WORK/$copy/OpenScreens.app/Contents/embedded.provisionprofile"
    codesign --force --sign "$IDENTITY" --options runtime --timestamp=none "$WORK/$copy/OpenScreens.app" 2>/dev/null \
        && codesign --verify --deep --strict "$WORK/$copy/OpenScreens.app" \
        || { echo "The $copy copy could not be signed." >&2; exit 2; }
done
FROM=$(version "$WORK/older/OpenScreens.app")
TO=$(version "$WORK/newer/OpenScreens.app")

# --- What it is offered ---------------------------------------------------

cp -R "$WORK/newer/OpenScreens.app" "$WORK/image/"
ln -s /Applications "$WORK/image/Applications"
hdiutil create -volname "OpenScreens" -srcfolder "$WORK/image" -fs APFS -format ULFO -quiet "$WORK/valid/OpenScreens.dmg"
echo "A trial." > "$WORK/valid/OpenScreens.md"
"$TOOLS/generate_appcast" --ed-key-file "$WORK/trial.key" --download-url-prefix "http://127.0.0.1:$PORT/" \
    --embed-release-notes -o "$WORK/valid/appcast.xml" "$WORK/valid" >/dev/null 2>&1
"$TOOLS/sign_update" --verify --ed-key-file "$WORK/trial.key" "$WORK/valid/appcast.xml" >/dev/null 2>&1 \
    && grep -q 'sparkle:edSignature="' "$WORK/valid/appcast.xml" \
    || { echo "The trial's feed could not be signed." >&2; exit 2; }

for feed in unsigned altered spoiled; do
    mkdir -p "$WORK/$feed"
    cp "$WORK/valid/OpenScreens.dmg" "$WORK/valid/appcast.xml" "$WORK/$feed/"
done
python3 -I - "$WORK" <<'PY' || { echo "The feeds to be turned down could not be made." >&2; exit 2; }
import os, re, sys
work = sys.argv[1]

# The feed's signature is a comment at its end. Without it:
path = os.path.join(work, "unsigned", "appcast.xml")
feed = open(path).read()
bare = re.sub(r"<!-- sparkle-sign(-warning|atures):.*?-->", "", feed, flags=re.S)
assert "sparkle-signatures" in feed and "sparkle-signatures" not in bare
open(path, "w").write(bare)

# Signed, and then changed:
path = os.path.join(work, "altered", "appcast.xml")
feed = open(path).read()
changed = feed.replace("<title>", "<title>Changed: ", 1)
assert changed != feed
open(path, "w").write(changed)

# The download, with one byte in the middle turned over:
path = os.path.join(work, "spoiled", "OpenScreens.dmg")
middle = os.path.getsize(path) // 2
with open(path, "r+b") as image:
    image.seek(middle)
    byte = image.read(1)
    image.seek(middle)
    image.write(bytes([byte[0] ^ 0xFF]))
PY

# --- A trial ------------------------------------------------------------------

say() { # <ok or not> <what>
    if [ "$1" = yes ]; then echo "  ok    $2"; else echo "  FAIL  $2"; failures=$((failures + 1)); fi
}
asked_for() { grep -c "\"GET /$1 " "$RUN/server.log" 2>/dev/null; }
why() { # <when the trial began>: what Sparkle said about turning it down
    # By the name of the process: the log remembers a program by the first
    # place it ran from, which for Sparkle's installer is some earlier trial.
    /usr/bin/log show --start "$1" --style compact --info \
        --predicate 'subsystem == "org.sparkle-project.Sparkle" AND (process == "OpenScreens" OR process == "Autoupdate")' 2>/dev/null \
        | sed -E 's/^.*\[org\.sparkle-project\.Sparkle:Sparkle\] //' \
        | grep -E "rejected|does not match|could not be validated" | grep -v "^Error: " \
        | cut -c1-140 | head -1 | sed 's/^/  why   /'
}

# trial <feed folder> <how to open: -j or nothing> <seconds to wait>
# Leaves: quit, reopened, isolated (yes or no) and began (when it started).
trial() {
    rm -rf "${RUN:?}"
    mkdir -p "$RUN/home" "$RUN/data"
    cp -R "$WORK/older/OpenScreens.app" "$APP"
    # A first launch every time: Sparkle then looks at the feed as it starts.
    defaults delete "$TRIAL" >/dev/null 2>&1
    python3 -I -m http.server "$PORT" --bind 127.0.0.1 --directory "$WORK/$1" > "$RUN/server.log" 2>&1 &
    SERVER=$!
    sleep 1
    began=$(date "+%Y-%m-%d %H:%M:%S")
    # shellcheck disable=SC2086
    open -g $2 -n -a "$APP" --stderr "$RUN/said.log" \
        --env CFFIXED_USER_HOME="$RUN/home" --env OPENSCREENS_DATA_DIR="$RUN/data" \
        --env OPENSCREENS_UPDATE_FEED="http://127.0.0.1:$PORT/appcast.xml" \
        --env OPENSCREENS_UPDATE_UNASKED=1

    quit=no; reopened=no; isolated=no
    first=""
    start=$(date +%s)
    while [ $(( $(date +%s) - start )) -lt "$3" ]; do
        running=$(pgrep -f "$PROCESS" | tr '\n' ' ')
        if [ -z "$first" ]; then
            first=${running%% *}
        else
            case " $running " in *" $first "*) ;; *) quit=yes ;; esac
            for process in $running; do
                [ "$process" = "$first" ] && continue
                reopened=yes
                ps eww -o command= -p "$process" 2>/dev/null | tr ' ' '\n' \
                    | grep -q "^OPENSCREENS_DATA_DIR=$RUN/data$" && isolated=yes
                # Opened by Sparkle it comes to the front: closed at once.
                kill "$process" 2>/dev/null
                break 2
            done
        fi
        sleep 0.1
    done
    sleep 2
    pkill -f "$PROCESS" 2>/dev/null
    kill "$SERVER" 2>/dev/null
    wait "$SERVER" 2>/dev/null
    SERVER=""
}

refused() { # <feed folder> <what it is> <whether the download may be asked for>
    echo "$2"
    trial "$1" -j 20
    say "$([ "$(asked_for appcast.xml)" -ge 1 ] && echo yes || echo no)" "the feed was asked for"
    if [ "$3" = no ]; then
        say "$([ "$(asked_for OpenScreens.dmg)" -eq 0 ] && echo yes || echo no)" "nothing was downloaded"
    else
        say "$([ "$(asked_for OpenScreens.dmg)" -ge 1 ] && echo yes || echo no)" "the download was asked for"
    fi
    say "$([ "$(version "$APP")" = "$FROM" ] && echo yes || echo no)" "$FROM is still what is installed"
    why "$began"
}

real_preferences="$HOME/Library/Preferences/com.burakgon.openscreens.plist"
before=$(stat -f '%m' "$real_preferences" 2>/dev/null || echo none)

echo "An update from $FROM to $TO, the window $([ -n "$HOW" ] && echo hidden || echo shown)"
trial valid "$HOW" 90
say "$([ "$(asked_for appcast.xml)" -ge 1 ] && [ "$(asked_for OpenScreens.dmg)" -ge 1 ] && echo yes || echo no)" \
    "the feed and the download were asked for"
if [ -z "$HOW" ]; then
    # Otherwise this run says nothing about quitting from under a sheet.
    say "$(grep -q "update trial: .*the sheet is up" "$RUN/said.log" 2>/dev/null && echo yes || echo no)" \
        "the update's sheet was up when installing was chosen"
fi
say "$quit" "the app quit when Sparkle asked it to"
say "$([ "$(version "$APP")" = "$TO" ] && echo yes || echo no)" "$TO is what is installed now"
codesign --verify --deep --strict "$APP" >/dev/null 2>&1
say "$([ $? -eq 0 ] && echo yes || echo no)" "its signature holds"
say "$reopened" "Sparkle opened it again"
say "$isolated" "and what it opened kept to the trial's folder"
open -g -j -n -a "$APP"
sleep 6
say "$([ "$(pgrep -f "$PROCESS" | wc -l | tr -d ' ')" -ge 1 ] && echo yes || echo no)" "the new version stays open"
pkill -f "$PROCESS" 2>/dev/null

refused unsigned "A feed with its signature removed" no
refused altered "A feed changed after it was signed" no
refused spoiled "A download changed after it was signed" yes

echo "The app installed on this Mac"
after=$(stat -f '%m' "$real_preferences" 2>/dev/null || echo none)
say "$([ "$before" = "$after" ] && echo yes || echo no)" "its preferences were not written to"

[ "$failures" -eq 0 ] && echo "The update went through, and what should be refused was." \
    || echo "$failures of these did not come out as they should."
exit "$failures"
