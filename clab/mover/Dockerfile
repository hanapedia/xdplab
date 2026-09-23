# Moves a physical XDP-link port into a kind node's netns (clab/DESIGN.md
# "Giving nodes real NICs"). Runs as a network-mode: host containerlab node,
# so it needs docker's CLI (not the daemon -- talks to the host's socket,
# bind-mounted in) to look up the target node's PID, plus iproute2 for the
# move itself and a DHCP client to address the port before moving it.
FROM ghcr.io/cybozu/ubuntu:26.04.20260917

RUN apt-get update && apt-get install -y --no-install-recommends \
    iproute2 \
    isc-dhcp-client \
    docker.io \
    && rm -rf /var/lib/apt/lists/*
