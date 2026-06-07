#!/bin/bash
set -euo pipefail

# Container initialisation script — runs as PID 1's predecessor, then execs
# /sbin/init (systemd). All UniFi OS components are managed as internal systemd
# services; this script only sets up the environment they expect.

# ── Volume Symlinks ───────────────────────────────────────────────────────────
# Redirect internal paths to /unifi/<subdir> so all persistent state lives in
# a single named volume. Existing content is seeded into the target on first run.
declare -A SYMLINK_MAP=(
    ["/data"]="/unifi/data"
    ["/var/lib/mongodb"]="/unifi/db"
    ["/var/lib/unifi"]="/unifi/config"
    ["/var/log"]="/unifi/logs"
    ["/srv"]="/unifi/srv"
    ["/persistent"]="/unifi/persistent"
    ["/etc/rabbitmq/ssl"]="/unifi/rabbitmq-ssl"
    ["/usr/lib/unifi"]="/unifi/app"
)

for ORIG in "${!SYMLINK_MAP[@]}"; do
    TARGET="${SYMLINK_MAP[$ORIG]}"
    mkdir -p "$TARGET"

    # If the original path is a real directory (not yet a symlink), seed target.
    if [ -d "$ORIG" ] && [ ! -L "$ORIG" ]; then
        cp -a --no-clobber "$ORIG/." "$TARGET/" 2>/dev/null || true
        rm -rf "$ORIG"
    fi

    mkdir -p "$(dirname "$ORIG")"
    ln -sfn "$TARGET" "$ORIG"
    chmod 755 "$TARGET"
done

# ── UUID Management ───────────────────────────────────────────────────────────
# Written once; subsequent restarts reuse the persisted value.
if [ ! -f /unifi/data/uos_uuid ]; then
    if [ -n "${UOS_UUID:-}" ]; then
        echo "Setting UOS_UUID=$UOS_UUID"
        echo "$UOS_UUID" > /unifi/data/uos_uuid
    else
        RAW=$(cat /proc/sys/kernel/random/uuid)
        # Spoof a v5 UUID (bit 15 of the high time word = 0101).
        UOS_UUID=$(echo "$RAW" | sed 's/./5/15')
        echo "Generated UOS_UUID=$UOS_UUID"
        echo "$UOS_UUID" > /unifi/data/uos_uuid
    fi
fi

# ── Architecture Detection ────────────────────────────────────────────────────
ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
case "$ARCH" in
    amd64|x86_64)   FIRMWARE_PLATFORM=linux-x64 ;;
    arm64|aarch64)  FIRMWARE_PLATFORM=arm64 ;;
    *)
        echo "ERROR: Unsupported architecture: $ARCH" >&2
        exit 1
        ;;
esac
echo "FIRMWARE_PLATFORM=$FIRMWARE_PLATFORM"
echo "$FIRMWARE_PLATFORM" > /usr/lib/platform

# ── Version Stamp ─────────────────────────────────────────────────────────────
echo "UOS_SERVER_VERSION=$UOS_SERVER_VERSION"
echo "UOSSERVER.0000000.$UOS_SERVER_VERSION.0000000.000000.0000" > /usr/lib/version

# ── Network Setup ─────────────────────────────────────────────────────────────
# Create an eth0 macvlan alias from tap0 when eth0 is absent (requires NET_ADMIN
# capability and the macvlan kernel module loaded on the host).
if [ ! -d /sys/devices/virtual/net/eth0 ] && [ -d /sys/devices/virtual/net/tap0 ]; then
    ip link add name eth0 link tap0 type macvlan
    ip link set eth0 up
fi

# ── Service Directories ───────────────────────────────────────────────────────
# Create log directories with correct ownership before systemd starts services.
for SPEC in \
    "nginx:nginx:/var/log/nginx" \
    "mongodb:mongodb:/var/log/mongodb" \
    "rabbitmq:rabbitmq:/var/log/rabbitmq"; do
    IFS=':' read -r OWNER GROUP DIR <<< "$SPEC"
    if [ ! -d "$DIR" ]; then
        mkdir -p "$DIR"
        chown "$OWNER:$GROUP" "$DIR"
        chmod 755 "$DIR"
    fi
done

# MongoDB requires ownership of its data directory.
chown -R mongodb:mongodb /var/lib/mongodb

# ── System IP ─────────────────────────────────────────────────────────────────
# Writes/updates the system_ip entry in system.properties so UniFi devices can
# reach the controller at the correct address.
SYSTEM_PROPERTIES=/var/lib/unifi/system.properties
if [ -n "${UOS_SYSTEM_IP:-}" ]; then
    echo "UOS_SYSTEM_IP=$UOS_SYSTEM_IP"
    mkdir -p "$(dirname "$SYSTEM_PROPERTIES")"
    if [ ! -f "$SYSTEM_PROPERTIES" ]; then
        echo "system_ip=$UOS_SYSTEM_IP" > "$SYSTEM_PROPERTIES"
    elif grep -q "^system_ip=" "$SYSTEM_PROPERTIES"; then
        TMP=$(mktemp)
        sed "s/^system_ip=.*/system_ip=$UOS_SYSTEM_IP/" "$SYSTEM_PROPERTIES" > "$TMP"
        cat "$TMP" > "$SYSTEM_PROPERTIES"
        rm -f "$TMP"
    else
        echo "system_ip=$UOS_SYSTEM_IP" >> "$SYSTEM_PROPERTIES"
    fi
fi

# ── Hand off to systemd ───────────────────────────────────────────────────────
exec /sbin/init
