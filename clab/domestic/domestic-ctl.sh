#!/usr/bin/env bash
# "External" test targets on r5500, reachable from pods over the BGP-routed
# underlay -- same role and addressing as mooring/e2e_v2's domestic0/domestic1
# (network/cluster.clab.yaml.tmpl), but r5500 IS the router here, so these
# are plain docker containers wired to r5500 via a direct veth pair
# (--network none, manually addressed, plain L3 routing -- no bridge, since
# each subnet only ever has this one container on it) rather than
# containerlab-managed nodes. r5500-only.
set -euo pipefail

# name        gw               container-ip        image
DOMESTIC0=(domestic0 192.168.0.101   192.168.0.100/24  ghcr.io/cybozu/ubuntu-debug:24.04)
DOMESTIC1=(domestic1 192.168.10.101  192.168.10.100/24 ghcr.io/cybozu/testhttpd:0)

UNIT_NAME="xdplab-domestic.service"
UNIT_PATH="/etc/systemd/system/${UNIT_NAME}"
DOMESTIC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "error: must run as root" >&2
    exit 1
  fi
}

# domestic0 has no long-running default entrypoint (unlike testhttpd) --
# needs an explicit foreground command to stay up.
container_cmd() {
  [[ "$1" == domestic0 ]] && echo "sleep infinity" || echo ""
}

apply_one() {
  local name="$1" gw="$2" ip="$3" image="$4"
  local container="xdplab-${name}"
  local veth_h="veth-${name:0:4}${name: -1}h"   # e.g. domestic0 -> veth-dome0h (<=15 chars)
  local veth_c="veth-${name:0:4}${name: -1}c"

  if ! docker inspect "$container" &>/dev/null; then
    # NET_ADMIN: Docker excludes it by default, but the container needs it
    # to rename/address its own moved-in veth end via `docker exec`.
    docker run -d --name "$container" --network none --cap-add NET_ADMIN --restart unless-stopped \
      "$image" $(container_cmd "$name") >/dev/null
    echo "==> container $container ($image)"
  fi

  if ! docker exec --user root "$container" ip -4 addr show eth0 &>/dev/null; then
    local pid
    pid="$(docker inspect -f '{{.State.Pid}}' "$container")"
    ip link add "$veth_h" type veth peer name "$veth_c"
    ip addr add "${gw}/24" dev "$veth_h"
    ip link set "$veth_h" up
    ip link set "$veth_c" netns "$pid"
    docker exec --user root "$container" ip link set "$veth_c" name eth0
    docker exec --user root "$container" ip addr add "$ip" dev eth0
    docker exec --user root "$container" ip link set eth0 up
    docker exec --user root "$container" ip route replace default via "$gw" dev eth0
    echo "==> $container: eth0 $ip via $gw (routed, host end $veth_h $gw/24)"
  fi
}

teardown_one() {
  local name="$1"
  local container="xdplab-${name}"
  local veth_h="veth-${name:0:4}${name: -1}h"
  # docker rm destroys the container's netns, which takes its veth peer
  # (eth0) with it -- and since this is a plain point-to-point veth pair (no
  # bridge holding the host end open independently), that also removes
  # veth_h. The explicit delete below is just a safety net for a partial
  # apply that created the veth but never got as far as moving its peer in.
  docker rm -f "$container" >/dev/null 2>&1 || true
  ip link show "$veth_h" &>/dev/null && ip link del "$veth_h"
  echo "==> torn down $name"
}

status_one() {
  local name="$1"
  local veth_h="veth-${name:0:4}${name: -1}h"
  local container="xdplab-${name}"
  echo "--- $name ---"
  ip -brief link show "$veth_h" 2>/dev/null || echo "$veth_h: absent"
  docker exec --user root "$container" ip -4 addr show eth0 2>/dev/null || echo "$container: absent or unaddressed"
}

cmd_apply() {
  require_root
  apply_one "${DOMESTIC0[@]}"
  apply_one "${DOMESTIC1[@]}"
}

cmd_teardown() {
  require_root
  teardown_one "${DOMESTIC0[0]}"
  teardown_one "${DOMESTIC1[0]}"
}

cmd_setup() {
  require_root
  ln -sf "${DOMESTIC_DIR}/${UNIT_NAME}" "${UNIT_PATH}"
  echo "==> ${UNIT_PATH} -> ${DOMESTIC_DIR}/${UNIT_NAME}"
  systemctl daemon-reload
  systemctl enable --now "${UNIT_NAME}"
  systemctl --no-pager status "${UNIT_NAME}" || true
}

cmd_destroy() {
  require_root
  systemctl disable --now "${UNIT_NAME}" 2>/dev/null || true
  rm -f "${UNIT_PATH}"
  systemctl daemon-reload
  cmd_teardown
}

cmd_status() {
  systemctl --no-pager status "${UNIT_NAME}" 2>/dev/null || echo "${UNIT_NAME}: not installed"
  echo
  status_one "${DOMESTIC0[0]}"
  status_one "${DOMESTIC1[0]}"
}

case "${1:-}" in
  setup) cmd_setup ;;
  destroy) cmd_destroy ;;
  status) cmd_status ;;
  apply) cmd_apply ;;      # invoked by the systemd unit itself, not normally called directly
  teardown) cmd_teardown ;; # invoked by the systemd unit itself, not normally called directly
  *)
    echo "usage: $0 {setup|destroy|status}" >&2
    exit 1
    ;;
esac
