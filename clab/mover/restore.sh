#!/bin/sh
# Reverses move.sh: moves a physical XDP-link port back to the host netns
# (clab/DESIGN.md "Giving nodes real NICs"). Runs directly on the host (not
# inside a container, unlike move.sh) -- normal `/proc` access, no
# network-mode: host or docker-socket bind-mount needed.
# Usage: restore.sh <target-container> <netns-iface-name> <host-port-name>
set -eu

TARGET="${1:?usage: restore.sh <target-container> <netns-iface-name> <host-port-name>}"
IFACE="${2:?usage: restore.sh <target-container> <netns-iface-name> <host-port-name>}"
PORT="${3:?usage: restore.sh <target-container> <netns-iface-name> <host-port-name>}"

docker exec "$TARGET" ip link set "$IFACE" down
# The interface still carries its original $PORT name as an altname from
# before it was ever moved -- renaming back to that same name conflicts
# with it otherwise ("RTNETLINK answers: File exists").
docker exec "$TARGET" ip link property del dev "$IFACE" altname "$PORT" 2>/dev/null || true
docker exec "$TARGET" ip link set "$IFACE" name "$PORT"

# `docker exec ... ip link set $PORT netns 1` would be a no-op: PID 1 inside
# the container is *its own* init, not the host's, so "netns 1" resolves to
# the container's own netns, i.e. nowhere. Reach the container's netns from
# the host side instead (same trick as move.sh, just in reverse), then
# `ip -n` to run the actual move as a setns() from this (host) process --
# PID 1 means the right thing there, since the process doing the resolving
# never left the host's own PID namespace.
PID="$(docker inspect -f '{{.State.Pid}}' "$TARGET")"
mkdir -p /var/run/netns
touch "/var/run/netns/$TARGET"
mount --bind "/proc/$PID/ns/net" "/var/run/netns/$TARGET"
ip -n "$TARGET" link set "$PORT" netns 1
umount "/var/run/netns/$TARGET"
rm -f "/var/run/netns/$TARGET"

ip link set "$PORT" down

echo "==> restored: $PORT back in host netns"
ip -4 addr show "$PORT"
