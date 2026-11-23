#!/bin/bash
# Starts every server of the lab, each on its own port, and waits.
#
#   5901  TigerVNC   VNC password
#   5902  TigerVNC   as installed: TLSVnc or a VNC password
#   5903  TigerVNC   TLS with a self-signed certificate, VNC password
#   5904  TigerVNC   TLS with a self-signed certificate, user name and password
#   5905  TigerVNC   RSA-AES, password
#   5906  TigerVNC   RSA-AES-256, user name and password
#   5907  TigerVNC   RSA-AES for sign-in only (RA2ne), password
#   5908  TigerVNC   no sign-in
#   5911  x11vnc     VNC password
#   5912  x11vnc     TLS with a self-signed certificate, VNC password
#   5921  wayvnc     no sign-in
#   5922  wayvnc     as Raspberry Pi OS sets it up: TLS or RSA-AES, user name
#                    and password
#
# The password is "secret12"; the user is "demo" with "demo-secret".
set -u

LAB=/lab
mkdir -p "$LAB" /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix

printf 'secret12\nsecret12\n' | vncpasswd -f > "$LAB/passwd"
chmod 600 "$LAB/passwd"

# A certificate no authority has signed, as a server makes for itself.
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -subj "/CN=compat-lab" -addext "subjectAltName=DNS:compat-lab,IP:127.0.0.1" \
    -keyout "$LAB/tls-key.pem" -out "$LAB/tls-cert.pem" 2>/dev/null
openssl genrsa -traditional -out "$LAB/rsa-key.pem" 2048 2>/dev/null

# What Plain sign-in checks a user name and password against.
cat > /etc/pam.d/vnc <<'PAM'
auth    required pam_unix.so
account required pam_unix.so
PAM

# Something to see, to type into and to click on.
desktop() {
    local display=$1
    (
        export DISPLAY=$display
        for _ in $(seq 50); do xdpyinfo >/dev/null 2>&1 && break; sleep 0.1; done
        xsetroot -solid '#2f6f9f'
        # No window manager: the terminal has the keyboard while the pointer
        # is over it, and it fills the screen's top left corner.
        exec xterm -geometry 100x30+0+0 -fa Monospace -fs 11 \
            -bg '#101418' -fg '#e6e6e6' -e bash --norc
    ) >/dev/null 2>&1 &
}

tiger() {
    local number=$1; shift
    Xvnc ":$number" -rfbport "$((5900 + number))" -geometry 1280x800 -depth 24 \
        -AlwaysShared -AcceptSetDesktopSize -desktop "TigerVNC $number" \
        "$@" > "$LAB/tiger-$number.log" 2>&1 &
    desktop ":$number"
}

tiger 1 -SecurityTypes VncAuth -PasswordFile "$LAB/passwd"
tiger 2 -PasswordFile "$LAB/passwd"
tiger 3 -SecurityTypes X509Vnc -PasswordFile "$LAB/passwd" \
    -X509Cert "$LAB/tls-cert.pem" -X509Key "$LAB/tls-key.pem"
tiger 4 -SecurityTypes X509Plain -PlainUsers demo \
    -X509Cert "$LAB/tls-cert.pem" -X509Key "$LAB/tls-key.pem"
tiger 5 -SecurityTypes RA2 -RSAKey "$LAB/rsa-key.pem" -PasswordFile "$LAB/passwd"
tiger 6 -SecurityTypes RA2_256 -RSAKey "$LAB/rsa-key.pem" -RequireUsername \
    -PlainUsers demo
tiger 7 -SecurityTypes RA2ne -RSAKey "$LAB/rsa-key.pem" -PasswordFile "$LAB/passwd"
tiger 8 -SecurityTypes None

# x11vnc shares a display something else drew: here a virtual one.
x11() {
    local number=$1; shift
    # -noreset: the server would otherwise start afresh, and forget its
    # background, whenever the last program showing something left.
    Xvfb ":$number" -screen 0 1280x800x24 -noreset > "$LAB/xvfb-$number.log" 2>&1 &
    desktop ":$number"
    (
        for _ in $(seq 50); do DISPLAY=":$number" xdpyinfo >/dev/null 2>&1 && break; sleep 0.1; done
        exec x11vnc -display ":$number" -rfbport "$((5900 + number))" -forever -shared \
            -noxdamage -desktop "x11vnc $number" "$@"
    ) > "$LAB/x11vnc-$number.log" 2>&1 &
}

x11vnc -storepasswd secret12 "$LAB/x11vnc-passwd" >/dev/null 2>&1
cat "$LAB/tls-key.pem" "$LAB/tls-cert.pem" > "$LAB/x11vnc-tls.pem"
# -debug_sel has x11vnc write down the text it is sent, which the tests read.
x11 11 -rfbauth "$LAB/x11vnc-passwd" -debug_sel
x11 12 -rfbauth "$LAB/x11vnc-passwd" -debug_sel \
    -ssl "$LAB/x11vnc-tls.pem" -vencrypt only:nodh -anontls never

# wayvnc shares a Wayland desktop: here sway with no screen of its own.
wayland() {
    local name=$1 port=$2 config=$3
    local runtime="/tmp/wayland-$name"
    mkdir -p "$runtime"; chmod 700 "$runtime"
    (
        export XDG_RUNTIME_DIR=$runtime WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
               WLR_RENDERER=pixman WLR_HEADLESS_OUTPUTS=1 XDG_SESSION_TYPE=wayland
        cat > "$runtime/sway.conf" <<SWAY
output HEADLESS-1 resolution 1280x800 bg #2f6f9f solid_color
default_border none
# A window in the corner, as on the X desktops, with the desktop around it.
for_window [app_id="foot"] floating enable, resize set 900 500, move position 0 0
exec foot --font=monospace:size=11 bash --norc
exec wayvnc --config=$config --output=HEADLESS-1 0.0.0.0 $port
SWAY
        exec sway --unsupported-gpu --config "$runtime/sway.conf"
    ) > "$LAB/sway-$name.log" 2>&1 &
}

: > "$LAB/wayvnc-open.conf"
cat > "$LAB/wayvnc-pi.conf" <<CONF
enable_auth=true
enable_pam=true
private_key_file=$LAB/tls-key.pem
certificate_file=$LAB/tls-cert.pem
rsa_private_key_file=$LAB/rsa-key.pem
CONF
wayland open 5921 "$LAB/wayvnc-open.conf"
wayland pi 5922 "$LAB/wayvnc-pi.conf"

echo "compat-lab: servers started"
exec sleep infinity
