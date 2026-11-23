# Real VNC servers for OpenScreens to be tried against. See README.md here.
FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        tigervnc-standalone-server tigervnc-tools \
        x11vnc xvfb \
        wayvnc sway foot wl-clipboard \
        xterm xdotool xclip x11-utils x11-xserver-utils xfonts-base \
        openssl ca-certificates procps \
    && rm -rf /var/lib/apt/lists/*

# Someone to sign in as, for the servers that ask for a user name.
RUN useradd --create-home --shell /bin/bash demo \
    && echo 'demo:demo-secret' | chpasswd

COPY start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh
ENTRYPOINT ["/usr/local/bin/start.sh"]
