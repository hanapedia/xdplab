#!/usr/bin/env bash
# Sets up / tears down the containerized pull-through registry mirrors +
# systemd template unit on r5500 -- one instance per line in
# regmirror/mirrors.conf, each a registry:2 proxy cache for one upstream
# registry, reachable from both XDP links (host networking). r5500-only.
set -euo pipefail

UNIT_TEMPLATE="xdplab-regmirror@.service"
CONFIG_DIR="/etc/xdplab/regmirror"
UNIT_PATH="/etc/systemd/system/${UNIT_TEMPLATE}"
STORAGE_ROOT="/var/lib/xdplab/regmirror"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REGMIRROR_DIR="${REPO_DIR}/regmirror"
MIRRORS_CONF="${REGMIRROR_DIR}/mirrors.conf"

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "error: must run as root" >&2
    exit 1
  fi
}

each_mirror() {
  grep -v '^\s*#' "${MIRRORS_CONF}" | grep -v '^\s*$'
}

cmd_setup() {
  require_root

  mkdir -p "${CONFIG_DIR}"
  ln -sf "${REGMIRROR_DIR}/${UNIT_TEMPLATE}" "${UNIT_PATH}"
  echo "==> ${UNIT_PATH} -> ${REGMIRROR_DIR}/${UNIT_TEMPLATE}"

  docker pull registry:2

  systemctl daemon-reload

  while read -r name upstream port; do
    mkdir -p "${STORAGE_ROOT}/${name}"
    cat >"${CONFIG_DIR}/${name}.env" <<EOF
REGISTRY_PROXY_REMOTEURL=${upstream}
REGISTRY_HTTP_ADDR=:${port}
EOF
    echo "==> ${CONFIG_DIR}/${name}.env (${upstream} -> :${port})"
    systemctl enable --now "xdplab-regmirror@${name}.service"
  done < <(each_mirror)

  systemctl --no-pager status "xdplab-regmirror@*" || true
}

cmd_destroy() {
  require_root

  while read -r name _upstream _port; do
    systemctl disable --now "xdplab-regmirror@${name}.service" 2>/dev/null || true
    docker rm -f "xdplab-regmirror-${name}" >/dev/null 2>&1 || true
    rm -f "${CONFIG_DIR}/${name}.env"
  done < <(each_mirror)

  rm -f "${UNIT_PATH}"
  systemctl daemon-reload
  rmdir "${CONFIG_DIR}" 2>/dev/null || true
  echo "==> destroyed"
}

cmd_status() {
  while read -r name upstream port; do
    echo "--- ${name} (${upstream} -> :${port}) ---"
    systemctl --no-pager status "xdplab-regmirror@${name}.service" || true
    echo
  done < <(each_mirror)
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
