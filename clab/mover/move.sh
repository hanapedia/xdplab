#!/bin/sh
# Moves a physical XDP-link port from the host netns into a kind node's
# netns, addressed via DHCP first since the move flushes addresses
# (confirmed empirically, clab/DESIGN.md "Giving nodes real NICs").
# Usage: move.sh <port> <target-container> [<netns-iface-name>]
set -eu

PORT="${1:?usage: move.sh <port> <target-container> [<netns-iface-name>]}"
TARGET="${2:?usage: move.sh <port> <target-container> [<netns-iface-name>]}"
IFACE="${3:-node0}"

ip link set "$PORT" up
dhclient -1 "$PORT"

ADDR="$(ip -o -4 addr show "$PORT" | awk '{print $4}')"
GW="$(ip route show dev "$PORT" | awk '/^default/ {print $3}')"
echo "==> $PORT: $ADDR via $GW"

PID="$(docker inspect -f '{{.State.Pid}}' "$TARGET")"
echo "==> moving $PORT into $TARGET (pid $PID) as $IFACE"

# `ip link set <dev> netns <PID>` and `ip netns attach <name> <PID>` both
# resolve PID in the caller's own PID namespace -- this container only
# shares the host's *network* namespace (network-mode: host), not its PID
# namespace, so the host-reported PID above means nothing to either. Bind
# mount the target's netns file (reachable via the host /proc bind-mount)
# onto the standard /var/run/netns/<name> path instead -- a plain bind
# mount doesn't care about PID namespaces, only "ip netns" lookups do.
mkdir -p /var/run/netns
touch "/var/run/netns/$TARGET"
mount --bind "/hostproc/$PID/ns/net" "/var/run/netns/$TARGET"

ip link set "$PORT" netns "$TARGET"

umount "/var/run/netns/$TARGET"
rm -f "/var/run/netns/$TARGET"
docker exec "$TARGET" ip link set "$PORT" name "$IFACE"
docker exec "$TARGET" ip addr add "$ADDR" dev "$IFACE"
docker exec "$TARGET" ip link set "$IFACE" up
docker exec "$TARGET" ip route replace default via "$GW" dev "$IFACE"

echo "==> done: $TARGET/$IFACE"
docker exec "$TARGET" ip -4 addr show "$IFACE"
