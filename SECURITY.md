# Security

OpenScreens handles sign-in details and gives control of other computers, so
problems with it are taken seriously.

## Reporting a vulnerability

Please report it privately, through
[GitHub's private vulnerability reporting](https://github.com/burakgon/OpenScreens/security/advisories/new),
and not in a public issue.

Say what the problem is, how to reproduce it, and what an attacker gains.
You will get an answer within a week. Once a fix is released the report is
credited to you in the release notes, unless you would rather it was not.

## What counts

- Anything that lets someone else read or change what OpenScreens stores:
  the library, saved passwords, SSH keys, trusted host keys.
- Anything a malicious or compromised server can do to the device running
  OpenScreens beyond showing a picture — crashes included.
- Anything that weakens a protection the app claims: accepting an SSH host
  key it should not, sending a secret where it should not go, leaving
  unencrypted what is said to be encrypted.
- Anything that gets the Mac app to install an update that is not a release
  of this project.

## How updates are protected

The Mac app updates itself, with [Sparkle](https://sparkle-project.org),
from the feed attached to this project's newest release on GitHub.

- The feed has to be signed with the project's Ed25519 key, whose public
  half is in the app. A feed that is not, or that was changed after it was
  signed, is ignored.
- The disk image has to be signed with that key too, and is checked before
  it is opened.
- The app in it is checked before it takes the place of the one installed:
  a signed app is never replaced by one that is unsigned or whose signature
  does not hold, nor by an older version.
- Every release is notarised by Apple.

The private half of the key is not on GitHub and not in this repository.
Someone who took over the repository or its releases could keep copies of
the app from hearing of a new version. They could not make one install
anything that is not a release of this project.

Sparkle leaves a way back for a project that has lost its key, and it is
left open here. A copy of the app that has been offered nothing but feeds
it could not verify for twenty days will read one, though only for where
the download is: it shows none of what the feed says, asks before fetching
anything, and takes the disk image only if that is signed with the
project's key or with a Developer ID of the team that signed the app it
would replace.

## What is by design

Standard and Full Quality sessions with a Mac do not encrypt the picture, the
clipboard or sound; only signing in and typing are protected. Sessions with a
VNC server that uses a VNC password encrypt nothing. The app says so in its
statistics overlay and the README says how to protect such sessions. Reports
that these sessions can be watched on the network describe the protocol, not
a flaw in OpenScreens.

## Supported versions

Fixes go into the latest release.
