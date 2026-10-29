#!/bin/sh
# Runs Brambling as PUID:PGID (default 1000:1000) so files in /data belong to your user on the host.
set -e

DATA="${BRAMBLING_DATA:-/data}"

if [ "$(id -u)" = "0" ]; then
    mkdir -p "$DATA"
    # Only fix ownership when it's wrong, so a big media library isn't walked on every start.
    if [ "$(stat -c %u:%g "$DATA")" != "$PUID:$PGID" ]; then
        chown -R "$PUID:$PGID" "$DATA"
    fi
    if [ -z "$BRAMBLING_USER" ] || [ -z "$BRAMBLING_PASS" ]; then
        echo "Note: no BRAMBLING_USER/BRAMBLING_PASS set, the web UI is open to everyone who can reach this port. Keep it on your LAN." >&2
    fi
    exec setpriv --reuid="$PUID" --regid="$PGID" --clear-groups "$@"
fi

# Started with --user: run as that user directly.
exec "$@"
