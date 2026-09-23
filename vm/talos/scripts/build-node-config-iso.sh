#!/bin/sh
# Wraps a rendered Talos machine config into a filesystem-labeled "metal-iso"
# ISO, so the node picks it up at boot via talos.config=metal-iso with zero
# network dependency. Talos requires a complete, valid config (cluster CA
# present) to accept anything from this volume at all -- so each node needs
# its own ISO built from its own rendered config (talos/terraform's
# render.tf output), not a shared one.
#
# Input config.yaml is expected from talos/terraform's rendered/*.yaml
# (data.talos_machine_configuration, written to disk by render.tf).
set -eu

CONFIG_YAML="${1:?usage: build-node-config-iso.sh <config.yaml> <output-name.iso> [output-dir]}"
OUT_NAME="${2:?usage: build-node-config-iso.sh <config.yaml> <output-name.iso> [output-dir]}"
OUT_DIR="${3:-$(cd "$(dirname "$0")/.." && pwd)/out}"

mkdir -p "$OUT_DIR"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

cp "$CONFIG_YAML" "$WORKDIR/config.yaml"

OUT_ISO="$OUT_DIR/$OUT_NAME"
xorrisofs -joliet -rock -volid metal-iso -output "$OUT_ISO" "$WORKDIR"

echo "config ISO: $OUT_ISO"
