# Contributing to OpenScreens

Thank you for wanting to help. This page says how to report a problem, how to
build and test the app, and what a change needs before it can be merged.

## Reporting a problem

Open an [issue](https://github.com/burakgon/OpenScreens/issues/new/choose) and
say:

- what you did, what you expected and what happened instead;
- the OpenScreens version and whether it was the Mac, iPhone or iPad app;
- what you were connecting to: the kind of computer, its system version, and
  the mode (High Performance, Standard, Full Quality), and whether through
  Tailscale or an SSH tunnel.

For anything about the picture or the connection, turn on **Show Connection
Statistics** in Settings and include what the overlay says.

Please do not post screenshots of a remote screen that show anything private,
and never paste a password, an access token or a private key.

Security problems are reported privately — see [SECURITY.md](SECURITY.md).

## Building

You need Xcode 27.2 or later on macOS 26 or later.

```sh
cp Config/Signing.example.xcconfig Config/Signing.xcconfig   # set your team
open OpenScreens.xcodeproj
```

The Xcode project is generated from `project.yml`. If you add a target or
change its settings, edit `project.yml`, run `xcodegen generate` and commit
both. Adding or moving source files inside the package needs neither.

## Testing

```sh
swift test --package-path Packages/OpenScreensKit      # unit and end-to-end tests
swift test --package-path Vendor/rootshell-vnc \
  --filter "RFBProtocolTests|RFBTransportTests"        # the protocol engine
xcodebuild test -project OpenScreens.xcodeproj -scheme "OpenScreens iOS" \
  -destination "platform=iOS Simulator,name=iPhone 18 Pro"   # interface tests
```

A change to behaviour comes with a test that fails without it. Where a test
needs something to connect to, use `RFBTestServer`, which records what a
client sent.

Debug builds can be driven from the environment — open an address, type,
press keys, write a report of the session — which is how most protocol work
here was checked against real computers. `DebugAutomation.swift` lists the
variables.

## Making a release

For whoever holds the keys. A release is a version in `Config/Base.xcconfig`,
a section for it in `CHANGELOG.md`, and then:

```sh
scripts/sync-changelog.sh        # the app shows what is new from its own copy
SPARKLE_KEY=... scripts/release-mac.sh dist     # signed, notarised, with its update feed
scripts/update-trial.sh --shown OpenScreens-<last>.dmg dist/OpenScreens-<this>.dmg
scripts/publish-mac.sh dist                     # the release on GitHub
scripts/release-ios.sh                          # the build for TestFlight
```

Each script says at its top which keys it wants and where they come from.
The Mac release is three files, and installed copies of the app find the
third, `appcast.xml`, on the newest release: a release published without it
is one they never hear of.

`update-trial.sh` is the release being taken as an update, by a copy of the
release people have, on your Mac and without touching the app you have
installed. It is the older version that does the updating, so this is the
only look there is at what is about to happen on everyone's Mac. Publish
what came through it.

The icon is `Apps/Shared/AppIcon.icon`; after changing it,
`swift scripts/render-icon.swift` redraws the pictures of it in the
read-me.

## What a change needs

- **One thing per pull request**, described by what it does for the person
  using the app.
- **Tests pass**, on both platforms if the change touches shared code.
- **Claims are checked.** If a comment or a message says the remote computer
  does something, that was observed, not assumed. Much of the protocol is
  undocumented, and a confident guess costs the next person a day.
- **The engine stays upstreamable.** Changes under `Vendor/rootshell-vnc` are
  separate commits prefixed `engine:`, each standing on its own, so they can
  be offered upstream and re-applied when the engine is updated.
- **No code from projects whose licence is not compatible with MIT.** Notes
  about a protocol are fine to learn from; copied GPL or AGPL code is not.

## Style

Swift 6 with strict concurrency. Follow the code around you: doc comments
that say why rather than what, names that read as sentences at the call
site, no abbreviations. User-facing text is in plain English, in sentence
case for sentences and title case for buttons and menu items.
