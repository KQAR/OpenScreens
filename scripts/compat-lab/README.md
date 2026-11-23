# The compatibility lab

Real VNC servers in a container, set up the ways people set them up, and
tests that open a session to each and then look inside the container at
what arrived there: what was typed, where the pointer is, what is on the
clipboard, how large the desktop is.

```sh
scripts/compat-lab/lab.sh test     # start the servers and run the tests
scripts/compat-lab/lab.sh up       # only start them, to connect by hand
scripts/compat-lab/lab.sh down
```

It needs Docker, or anything that answers to `docker`, and is not part of
`swift test` or of CI: the tests are skipped unless the lab is up.
`OPENSCREENS_COMPAT_LAB_PORTS=5901,5922` runs them against some of the
servers only.

| Port | Server | Sign-in |
|---|---|---|
| 5901 | TigerVNC 1.15 | VNC password |
| 5902 | TigerVNC | as installed: anonymous TLS or a VNC password |
| 5903 | TigerVNC | TLS with a self-signed certificate, VNC password |
| 5904 | TigerVNC | TLS with a self-signed certificate, user name and password |
| 5905 | TigerVNC | RSA-AES, password |
| 5906 | TigerVNC | RSA-AES-256, user name and password |
| 5907 | TigerVNC | RSA-AES for the sign-in only, password |
| 5908 | TigerVNC | none |
| 5911 | x11vnc 0.9.17 | VNC password |
| 5912 | x11vnc | TLS with a self-signed certificate, VNC password |
| 5921 | wayvnc 0.9.1 | none |
| 5922 | wayvnc | as Raspberry Pi OS sets it up: TLS or RSA-AES, user name and password |

The password is `secret12`. The user is `demo` with `demo-secret`. Every
server listens on 127.0.0.1 only.

To add a server, start it in [`start.sh`](start.sh), publish its port in
[`lab.sh`](lab.sh) and describe it in `CompatibilityLab.allServers` in
[`CompatibilityLabTests.swift`](../../Packages/OpenScreensKit/Tests/OpenScreensUITests/CompatibilityLabTests.swift).
Every test then runs against it.

One thing is not tested: text copied on an x11vnc desktop arriving here.
In a display with nothing but a terminal in it x11vnc does not pass it on.
