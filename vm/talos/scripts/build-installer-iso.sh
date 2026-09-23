#!/bin/sh
# Builds the shared Talos metal installer ISO with talos.config=metal-iso baked
# into the kernel cmdline, via the siderolabs/imager container. One ISO, used
# by every VM's install cdrom (terraform's var.install_iso_path) — the thing
# that varies is the separate metal-iso config volume delivering
# .machine.kernel.modules, built by build-node-config-iso.sh.
set -eu

TALOS_VERSION="${1:?usage: build-installer-iso.sh <talos-version> [output-dir]}"
OUT_DIR="${2:-$(cd "$(dirname "$0")/.." && pwd)/out}"

mkdir -p "$OUT_DIR"

docker run --rm -v "$OUT_DIR:/out" \
  "ghcr.io/siderolabs/imager:${TALOS_VERSION}" \
  iso \
  --platform metal \
  --arch amd64 \
  --extra-kernel-arg "talos.config=metal-iso"

echo "installer ISO: $OUT_DIR/metal-amd64.iso"
