#!/usr/bin/env bash
# Sets up / tears down the containerized BIRD BGP instance + systemd unit
# on the local machine. The host's own hostname (r9600 or r5500, per
# SPEC.md) selects which bird/conf/<host>.conf gets mounted; override with
# XDPLAB_HOST if a machine is renamed/reimaged.
set -euo pipefail

IMAGE="ghcr.io/cybozu/bird:3.2.2.1"
CONTAINER_NAME="bird-bgp"
UNIT_NAME="bird-bgp.service"
CONFIG_DIR="/etc/xdplab/bird"
CONFIG_PATH="${CONFIG_DIR}/bird.conf"
UNIT_PATH="/etc/systemd/system/${UNIT_NAME}"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIRD_DIR="${REPO_DIR}/bird"

host_name() {
  echo "${XDPLAB_HOST:-$(hostname)}"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "error: must run as root" >&2
    exit 1
  fi
}

cmd_setup() {
  require_root
  local host src_conf
  host="$(host_name)"
  src_conf="${BIRD_DIR}/conf/${host}.conf"
  [[ -f "${src_conf}" ]] || { echo "error: no config at ${src_conf} (unrecognized host '${host}' — set XDPLAB_HOST=r9600|r5500)" >&2; exit 1; }

  echo "==> host: ${host}"

  mkdir -p "${CONFIG_DIR}"
  ln -sf "${src_conf}" "${CONFIG_PATH}"
  echo "==> ${CONFIG_PATH} -> ${src_conf}"

  ln -sf "${BIRD_DIR}/${UNIT_NAME}" "${UNIT_PATH}"
  echo "==> ${UNIT_PATH} -> ${BIRD_DIR}/${UNIT_NAME}"

  docker pull "${IMAGE}"

  systemctl daemon-reload
  systemctl enable --now "${UNIT_NAME}"
  systemctl --no-pager status "${UNIT_NAME}"
}

cmd_reload() {
  require_root
  # `enable --now` on an already-active unit is a no-op -- and the running
  # container's bind mount was resolved against the config file's inode at
  # its last start, so a plain `birdc configure` inside it just re-reads
  # that same stale inode if the file's been rsynced (replaced, not edited
  # in place) since. An explicit restart re-resolves the bind mount against
  # the current file.
  systemctl restart "${UNIT_NAME}"
  systemctl --no-pager status "${UNIT_NAME}"
}

cmd_destroy() {
  require_root
  systemctl disable --now "${UNIT_NAME}" 2>/dev/null || true
  rm -f "${UNIT_PATH}"
  systemctl daemon-reload
  rm -f "${CONFIG_PATH}"
  rmdir "${CONFIG_DIR}" 2>/dev/null || true
  docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  echo "==> destroyed"
}

cmd_status() {
  systemctl --no-pager status "${UNIT_NAME}" || true
  echo
  docker exec "${CONTAINER_NAME}" birdc show protocols || true
}

case "${1:-}" in
  setup) cmd_setup ;;
  reload) cmd_reload ;;
  destroy) cmd_destroy ;;
  status) cmd_status ;;
  *)
    echo "usage: $0 {setup|reload|destroy|status}" >&2
    exit 1
    ;;
esac
