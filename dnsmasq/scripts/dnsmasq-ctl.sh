#!/usr/bin/env bash
# Sets up / tears down the containerized dnsmasq DHCP instance + systemd unit
# on r5500 — serves per-MAC static reservations to VM1/VM2 over the two XDP
# point-to-point links (DESIGN.md §1.2/§3). r5500-only; unlike bird-ctl.sh
# there's no per-hostname config, since dnsmasq only ever runs here.
set -euo pipefail

IMAGE="xdplab/dnsmasq:local"
CONTAINER_NAME="xdplab-dnsmasq"
UNIT_NAME="xdplab-dnsmasq.service"
CONFIG_DIR="/etc/xdplab/dnsmasq"
CONFIG_PATH="${CONFIG_DIR}/dnsmasq.conf"
UNIT_PATH="/etc/systemd/system/${UNIT_NAME}"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DNSMASQ_DIR="${REPO_DIR}/dnsmasq"

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "error: must run as root" >&2
    exit 1
  fi
}

cmd_setup() {
  require_root

  mkdir -p "${CONFIG_DIR}"
  ln -sf "${DNSMASQ_DIR}/dnsmasq.conf" "${CONFIG_PATH}"
  echo "==> ${CONFIG_PATH} -> ${DNSMASQ_DIR}/dnsmasq.conf"

  ln -sf "${DNSMASQ_DIR}/${UNIT_NAME}" "${UNIT_PATH}"
  echo "==> ${UNIT_PATH} -> ${DNSMASQ_DIR}/${UNIT_NAME}"

  docker build -t "${IMAGE}" "${DNSMASQ_DIR}"

  systemctl daemon-reload
  systemctl enable --now "${UNIT_NAME}"
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
  echo "==> active leases:"
  docker exec "${CONTAINER_NAME}" cat /run/dnsmasq/dnsmasq.leases 2>/dev/null || true
}

case "${1:-}" in
  setup) cmd_setup ;;
  destroy) cmd_destroy ;;
  status) cmd_status ;;
  *)
    echo "usage: $0 {setup|destroy|status}" >&2
    exit 1
    ;;
esac
