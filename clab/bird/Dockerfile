# Same upstream image the underlay already uses (bird/bird-bgp.service at
# the repo root), plus debugging tools -- useful here since these instances
# run inside kind node netnses, not reachable the same way the host-level
# ones are.
FROM ghcr.io/cybozu/bird:3.2.2.1

RUN apt-get update && apt-get install -y --no-install-recommends \
    iproute2 iputils-ping traceroute tcpdump \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /run/bird
