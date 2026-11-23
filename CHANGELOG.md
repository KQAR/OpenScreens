# Changelog

Notable changes to OpenScreens. Versions follow
[Semantic Versioning](https://semver.org).

## 1.2.0

A release for computers that are not Macs, after the questions people asked
when the project was passed around: does it work with Linux, with Windows,
with a Raspberry Pi?

- **Raspberry Pi OS works as it comes.** Its VNC server asks for your user
  name and password over RSA-AES or TLS, and OpenScreens could do neither,
  so a Pi with VNC simply turned on could not be connected to. The same
  goes for **RealVNC servers**, which speak RSA-AES by default, and for
  TigerVNC and x11vnc set up with TLS.
- **A computer that encrypts its own connections is asked about once.** Its
  certificate, or its key, is one nobody has signed, so the first connection
  shows a fingerprint to check, as SSH does. After that OpenScreens stops,
  showing both fingerprints, if the computer presents another. The list is
  under **SSH Keys** in Settings.
- **A VNC server's desktop fits the screen.** TigerVNC, and wayvnc on a
  screen of its own, are asked for a desktop in the shape of your window or
  phone, and again when it is resized or turned. Computers that are not
  Macs now start with **Fit This Display**; **Remote Display** puts the
  desktop back as it was found.
- **A computer known by its certificate or key has to go on presenting
  it.** If something answers in its place and offers a sign-in without one,
  OpenScreens stops before a password is sent, and says why.
- A server that stops waiting while a fingerprint is being checked, as
  x11vnc does after twenty seconds, is connected to again once you agree.
- A server that needs a user name is asked for with a field for one, where
  the prompt used to offer only a password.
- Turning down a computer's certificate or key says so, where it used to
  ask for the password again.
- A VNC server that lists what it offers inside VeNCrypt, as TigerVNC does,
  is signed in to with what it has there.
- The statistics overlay says **TLS**, **AES-128** or **AES-256** for a VNC
  session that is encrypted.

Behind this is a lab of real servers. `scripts/compat-lab` runs TigerVNC,
x11vnc and wayvnc in twelve configurations, and a session is opened to
each to check what was typed, where the pointer went, what reached the
clipboard, the size of the desktop, both reduced and lossless colour, and
every answer to the question about a certificate or key.

## 1.1.1

- **Opening a session no longer freezes the app.** Version 1.1.0 showed the
  status bar wherever a screen had room for it, and what a screen keeps
  clear depends on whether the bar is showing. On an iPhone Duo with iOS
  27.3 the two did not agree: each change undid the other, the interface
  never came to rest, and the system ended the app. The status bar is
  hidden for as long as a session is on the screen, as it was in 1.0, and
  nothing about the layout depends on anything the layout changes.
- Two layouts that keep replacing each other are noticed and stopped,
  whatever sets them off.
- A foldable held at the very angle where the trackpad deck comes out no
  longer has it come and go.

## 1.1.0

A release for iPhone and iPad, after the first use on real devices.

- **A desktop sized for the screen it is shown on.** A phone held upright
  was given a desktop 1024 points wide: text at two fifths of its size and
  about eight megapixels to send, the most a Mac will send at 60 frames a
  second. It now gets one 720 points wide, with about half the pixels and
  text half as large again. "More Space on Small Screens" brings the wider
  desktop back.
- **The picture fills the screen.** It goes down to the bottom edge instead
  of stopping above the home indicator, and starts just below where a
  screen's rounded corners would cut into the Mac's menu bar.
- **Controls that keep out of the way.** They no longer float over the
  Dock. Where a screen has a strip the picture cannot use, down the side of
  an iPhone Duo's cover display or of any iPhone on its side, they stand
  there, always in view. Anywhere else they come out of the top and are put
  away to a small handle as soon as the remote screen is touched. They can
  be moved to the bottom, or kept in view.
- **Typing without losing sight of the screen.** A keyboard or the trackpad
  deck used to shrink the picture to what was left above it. The picture now
  keeps its size and slides up to show where the pointer is.
- The trackpad deck comes out by itself only on a foldable set down like a
  laptop, not whenever it is held with a slight bend, and can be put away
  then too.
- The status bar is shown beside a sensor housing, instead of that space
  being left black.
- iPhone presents frames at the display's full refresh rate.
- The statistics say whether video is decoded in hardware.
- A Mac that will not make a desktop as small as it is asked for is noticed,
  and asked for the size every Mac gives.

## 1.0.0

The first release, for macOS 26, iOS 26 and iPadOS 26.

- Apple Screen Sharing in High Performance, Standard and Full Quality modes,
  with remote sound, a desktop sized to the window or screen, and one, all
  or two virtual displays.
- VNC servers on Windows, Linux and Raspberry Pi.
- Typing that survives a difference in keyboard layouts, with key positions
  as an option for Macs; touch and trackpad modes, gestures, hardware
  keyboards, mice, trackpads and Apple Pencil on iPhone and iPad.
- A library with groups, tags, favourites, recents, previews and search,
  synced through iCloud, with backups.
- Nearby computers through Bonjour and tailnet devices through Tailscale.
- SSH tunnels with password or key sign-in and host key verification.
- Shared clipboard, curtain mode, observe only, lock on disconnect,
  Wake-on-LAN, one-tap shortcuts, Type Text and connection statistics.
- Files copied to and from a Mac by dragging them onto and off its screen,
  and a file browser that copies files and folders both ways over SFTP.
- An app lock, a menu bar item on the Mac, `vnc://` links and Shortcuts
  actions.
