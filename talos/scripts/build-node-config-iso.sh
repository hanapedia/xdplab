#!/bin/sh
# Wraps a rendered Talos machine config into a filesystem-labeled "metal-iso"
# ISO, so the node picks it up at boot via talos.config=metal-iso with zero
# network dependency. Currently carries only .machine.kernel.modules (ixgbe
# needs to be explicitly listed to load -- it ships in the image but Talos
# doesn't auto-probe it; see talos/patches/kernel-modules.yaml), so one output
# is shared by every VM -- no per-node addressing is baked in, that's DHCP.
#
# Input config.yaml is expected from:
#   talosctl gen config <cluster-name> <endpoint> \
#     --config-patch @talos/patches/kernel-modules.yaml \
#     --install-disk /dev/vda \
#     -t controlplane -o controlplane.yaml
set -eu

CONFIG_YAML="${1:?usage: build-node-config-iso.sh <config.yaml> [output-dir]}"
OUT_DIR="${2:-$(cd "$(dirname "$0")/.." && pwd)/out}"

mkdir -p "$OUT_DIR"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

cp "$CONFIG_YAML" "$WORKDIR/config.yaml"

OUT_ISO="$OUT_DIR/kernel-modules-config.iso"
xorrisofs -joliet -rock -volid metal-iso -output "$OUT_ISO" "$WORKDIR"

echo "config ISO: $OUT_ISO"
