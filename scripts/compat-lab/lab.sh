#!/bin/bash
# The compatibility lab: real VNC servers in a container, and the tests that
# open sessions to them.
#
#   scripts/compat-lab/lab.sh up      build the image and start the servers
#   scripts/compat-lab/lab.sh test    start them and run the tests
#   scripts/compat-lab/lab.sh down    stop them
#
# Needs Docker, or anything that answers to `docker`.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
name=openscreens-compat-lab
ports=(5901 5902 5903 5904 5905 5906 5907 5908 5911 5912 5921 5922)

up() {
    docker build --quiet --tag "$name" "$here" >/dev/null
    docker stop "$name" >/dev/null 2>&1 || true
    local publish=()
    for port in "${ports[@]}"; do
        publish+=(--publish "127.0.0.1:$port:$port")
    done
    docker run --detach --rm --name "$name" "${publish[@]}" "$name" >/dev/null
    # The last server to come up is the slowest: a Wayland session.
    for _ in $(seq 60); do
        if docker exec "$name" pgrep -x wayvnc >/dev/null 2>&1 \
            && [ "$(docker exec "$name" pgrep -c -x wayvnc)" = 2 ]; then
            sleep 1
            echo "The lab is up: ports ${ports[0]} to ${ports[${#ports[@]}-1]} on 127.0.0.1."
            return
        fi
        sleep 0.5
    done
    echo "The lab did not come up. Its log:" >&2
    docker logs "$name" >&2
    exit 1
}

case "${1:-}" in
    up)
        up
        ;;
    test)
        up
        shift
        OPENSCREENS_COMPAT_LAB=1 swift test \
            --package-path "$here/../../Packages/OpenScreensKit" \
            --filter CompatibilityLabTests "$@"
        ;;
    down)
        docker stop "$name" >/dev/null 2>&1 || true
        ;;
    *)
        sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
        exit 64
        ;;
esac
