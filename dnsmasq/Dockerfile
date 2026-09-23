FROM ghcr.io/cybozu/ubuntu:26.04.20260917

RUN apt-get update \
    && apt-get install -y --no-install-recommends dnsmasq \
    && rm -rf /var/lib/apt/lists/*

ENTRYPOINT ["dnsmasq", "--no-daemon", "--log-facility=-"]
