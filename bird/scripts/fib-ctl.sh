#!/usr/bin/env bash
# Sets up / tears down the dedicated "xdplab" kernel routing table (100)
# and the ip rule that makes it reachable, so BGP-learned routes stay out
# of the default (main) table. r9600-only — see DESIGN.md §1.3 and
# bird/conf/r9600.conf (`kernel table 100;`).
#
# The table itself needs no explicit creation: it appears once something
# (BIRD) writes a route into it. Setup/teardown here covers the table's
# name registration and the one unconditional ip rule (no destination
# match) that makes it reachable ahead of main.
set -euo pipefail

TABLE_ID=100
TABLE_NAME=xdplab
RT_TABLES_FILE="/etc/iproute2/rt_tables.d/${TABLE_NAME}.conf"
RULE_PRIORITY=500

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "error: must run as root" >&2
    exit 1
  fi
}

cmd_setup() {
  require_root

  mkdir -p "$(dirname "${RT_TABLES_FILE}")"
  echo "${TABLE_ID} ${TABLE_NAME}" > "${RT_TABLES_FILE}"
  echo "==> ${RT_TABLES_FILE}: ${TABLE_ID} ${TABLE_NAME}"

  if ! ip -4 rule show | grep -qF "lookup ${TABLE_NAME}"; then
    ip rule add lookup "${TABLE_NAME}" priority "${RULE_PRIORITY}"
    echo "==> ip rule: lookup ${TABLE_NAME}"
  fi
}

cmd_destroy() {
  require_root

  ip rule del lookup "${TABLE_NAME}" priority "${RULE_PRIORITY}" 2>/dev/null || true
  ip route flush table "${TABLE_NAME}" 2>/dev/null || true
  rm -f "${RT_TABLES_FILE}"
  echo "==> destroyed"
}

cmd_status() {
  echo "--- ip rule ---"
  ip -4 rule show | grep "${TABLE_NAME}" || echo "(none)"
  echo "--- table ${TABLE_NAME} ---"
  ip route show table "${TABLE_NAME}" 2>/dev/null || echo "(empty/absent)"
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
