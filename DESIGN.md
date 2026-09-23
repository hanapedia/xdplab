# XDP Homelab — Infrastructure Design Doc

## Overview

Two physical machines connected via two direct point-to-point 10GbE links (native-XDP-capable NICs, `ixgbe` driver family — X540/X550). Goal: a BGP-routed underlay between them, as a testbed for custom XDP forwarding (`bpf_fib_lookup`-based) accelerating traffic across the two links. What runs *on* the underlay (currently: Talos VMs, [`vm/`](vm/)) is a separate, swappable concern.

- **`r9600`** — workstation/hypervisor. Has no host-visible interface on the XDP links themselves today (both ports passed through to VMs, [`vm/DESIGN.md`](vm/DESIGN.md)) — its BIRD session rides the LAN instead.
- **`r5500`** — bare-metal router. Both NIC ports stay on the host. Runs BIRD (BGP) and, eventually, an XDP program doing FIB-based forwarding between the two links.

`r9600` and `r5500` also share an ordinary LAN subnet — the BGP session between them rides that LAN, not the XDP point-to-point links, which stay dedicated to link-endpoint ↔ `r5500` data traffic.

This is an experimentation environment, not a production system — rebuildability is valued over hardening.

### Topology

```
r9600                                   r5500
┌─────────────┐                        ┌─────────────┐
│  link 0 end │ ── enp?s0f0 ───cable── │ enp1s0f0    │
│ 10.10.0.2   │                        │ 10.10.0.1   │
│    /30      │                        │    /30      │  ── BIRD (BGP) ──
├─────────────┤                        ├─────────────┤     + kernel FIB
│  link 1 end │ ── enp?s0f1 ───cable── │ enp1s0f1    │     forwarding
│  10.10.1.2  │                        │ 10.10.1.1   │     between the
│    /30      │                        │    /30      │     two links
└─────────────┘                        └─────────────┘
```

`r5500` holds the "younger" (`.1`) address on each `/30` — it's the router. Once BIRD advertises the two `/30`s, `r9600`'s kernel FIB gets routes to both link-endpoint addresses directly (no separate management network needed).

### Addressing

| Link | Subnet | `r5500` (router) | Link-endpoint address |
|---|---|---|---|
| Link 0 | `10.10.0.0/30` | `10.10.0.1` (enp1s0f0) | `10.10.0.2` |
| Link 1 | `10.10.1.0/30` | `10.10.1.1` (enp1s0f1) | `10.10.1.2` |

| Host | LAN IP |
|---|---|
| `r9600` | `192.168.1.100` |
| `r5500` | `192.168.1.200` |

### BGP Mesh Overview

- **`r9600` ↔ `r5500`**: standard BGP (port 179) over the shared LAN, both in default netns. Unrelated to the XDP point-to-point links.
- **`r5500` ↔ link endpoints**: implicitly via `r5500`'s directly-connected `/30` routes, redistributed into BGP toward `r9600` (§1.2).
- **Link endpoints ↔ `r5500` (later)**: whatever runs the workload on the far end of each link may run its own BIRD instance peering with `r5500` to advertise further routes (e.g. pod CIDRs, [`vm/DESIGN.md`](vm/DESIGN.md) §4) — joining the same mesh.

---

## 1. Host Setup

### 1.1 `r9600` (hypervisor/workstation)

**Hardware:** dual-port native-XDP NIC (Intel `ixgbe` family — X540-AT2 or X550; X550 preferred if the PCIe slot is natively `3.0 x4`, since X540 is speced for `2.1 x8` and X550 avoids relying on the bandwidth math working out).

How the two ports get exposed to whatever runs the actual workload is approach-specific and documented alongside that approach — currently VFIO passthrough to Talos VMs, [`vm/DESIGN.md`](vm/DESIGN.md) §1.

**BIRD (BGP):**
- Peers with `r5500` over the LAN, imports the two `/30` routes into the kernel FIB — makes the link-endpoint addresses reachable from `r9600` once the session converges.
- Route installation: a dedicated kernel table (`100`/`xdplab`), not the default/main table — keeps BGP-learned routes separated from `r9600`'s normal LAN routing. Table + `ip rule` setup: §1.3.
- Deployment: containerized via systemd — §1.3. Config: [`bird/conf/r9600.conf`](bird/conf/r9600.conf).

### 1.2 `r5500` (router, bare metal)

**OS:** fresh Ubuntu 26.04. **Network backend: systemd-networkd** (switched from NetworkManager after the two backends fought over interfaces — netplan's default renderer started networkd regardless of an existing `renderer: NetworkManager` setting; consolidating to one backend fixed it).

**netplan** (`/etc/netplan/99-xdp-links.yaml`, global `renderer: networkd` set in the main netplan file):
```yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    enp1s0f0:
      match:
        macaddress: <mac-of-front-port>
      set-name: enp1s0f0
      addresses:
        - 10.10.0.1/30
    enp1s0f1:
      match:
        macaddress: <mac-of-back-port>
      set-name: enp1s0f1
      addresses:
        - 10.10.1.1/30
```
File permissions must be `600` (netplan refuses otherwise). Match by MAC + `set-name` so config survives PCI re-enumeration.

**LAN** (`/etc/netplan/02-lan.yaml`):
```yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    enp7s0:
      dhcp4: true
```
Plain DHCP — `enp7s0` has no `match`/`set-name` since it's a fixed onboard port, not affected by the PCI re-enumeration concern the XDP ports have.

**Routing sysctls** (`/etc/sysctl.d/99-xdp-routing.conf`):
```
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.enp1s0f0.rp_filter = 0
net.ipv4.conf.enp1s0f1.rp_filter = 0
```
`rp_filter` fully disabled (not loose mode) — asymmetric routing is expected once BGP/multi-path is in play. Apply with `sysctl --system`.

**DHCP (link-endpoint addressing):** `dnsmasq`, containerized (image: [`dnsmasq/Dockerfile`](dnsmasq/Dockerfile), `ghcr.io/cybozu/ubuntu` base) — one instance bound to `enp1s0f0`/`enp1s0f1` only (`port=0`, no DNS role; never touches the LAN or loopback), handing out the two `/30` addresses as static per-MAC reservations via `dhcp-range=...,static` + `dhcp-host=<mac>,<ip>`, keyed on whatever physical NIC MAC actually answers on each link. Deployment: containerized via systemd, same pattern as BIRD (§1.3) but image is built locally rather than pulled, since there's no upstream registry for it. Config: [`dnsmasq/dnsmasq.conf`](dnsmasq/dnsmasq.conf). Control: `dnsmasq/scripts/dnsmasq-ctl.sh setup|destroy|status`.

**BIRD (BGP):**
- Peers with `r9600` over the LAN (port 179), both default netns.
- Must explicitly export directly-connected routes into BGP — `protocol direct` doesn't redistribute by default; needs an export filter for the two `/30`s.
- Link-endpoint ↔ `r5500` traffic doesn't need BGP — that's plain kernel `ip_forward` between the two directly-connected subnets, active from day one regardless of BGP session state.
- Deployment: containerized via systemd — §1.3. Config: [`bird/conf/r5500.conf`](bird/conf/r5500.conf).

**Future (out of scope here, noted for context):** replace/augment plain kernel forwarding between the two ports with an XDP program using `bpf_fib_lookup()` against the same kernel FIB BIRD populates — no separate control-plane sync needed.

### 1.3 BIRD Deployment (Docker + systemd)

Both hosts run BIRD the same way — a container started at boot by a systemd unit — with only the mounted config differing per host:

```
bird/
├── bird-bgp.service     # systemd unit, identical on both hosts
├── conf/
│   ├── r9600.conf
│   └── r5500.conf
└── scripts/
    ├── bird-ctl.sh      # setup / destroy / status
    └── fib-ctl.sh       # setup / destroy / status — r9600's dedicated table + rules
```

**Image:** [`ghcr.io/cybozu/bird:3.2.2.1`](https://github.com/cybozu/neco-containers/tree/main/bird) — minimal multi-stage build of upstream BIRD 3.2.2. `kernel` and `direct` are core BIRD protocols (not part of the image's trimmed `--with-protocols` list), so both remain available. Entrypoint `bird -f` runs in the foreground, so systemd manages it as a plain `Type=simple` service with logs going straight to journald.

**Container invocation** (full unit: [`bird/bird-bgp.service`](bird/bird-bgp.service)):
```
docker run --rm --name bird-bgp \
  --network host \
  --read-only \
  --cap-drop ALL \
  --cap-add NET_ADMIN --cap-add NET_BIND_SERVICE --cap-add NET_RAW \
  --mount type=tmpfs,destination=/run/bird \
  --mount type=bind,source=/etc/xdplab/bird/bird.conf,target=/etc/bird/bird.conf,readonly \
  ghcr.io/cybozu/bird:3.2.2.1
```
- `--network host` — required: BIRD must see the host's real interfaces/routes (`protocol direct` on `r5500`) and write BGP-learned routes into the *host* kernel FIB on both ends.
- `--read-only` + `--cap-drop ALL`, re-adding only `NET_ADMIN` (kernel FIB), `NET_RAW`/`NET_BIND_SERVICE` (BGP socket). `tmpfs` at `/run/bird` gives BIRD a writable spot for its control socket/PID file despite the read-only root.
- Config is bind-mounted from a fixed host path rather than baked into the image — same image on both hosts, config is the only variable.

**systemd unit:** `Type=simple` wrapping the foreground `docker run` above; `Requires=docker.service`, `After=network-online.target`, `Restart=on-failure`. `ExecStartPre` force-removes any stale container and attempts a `docker pull` (prefixed `-`, so an offline reboot falls back to the cached image instead of failing to start).

**`bird/scripts/bird-ctl.sh setup|destroy|status`:**
- Uses the local hostname (`r9600`/`r5500`) directly as the config key; override with `XDPLAB_HOST` if a machine is renamed/reimaged.
- `setup`: symlinks `bird/conf/<hostname>.conf` → `/etc/xdplab/bird/bird.conf` and `bird/bird-bgp.service` → `/etc/systemd/system/` (symlinked, not copied, so `git pull` + `systemctl restart bird-bgp` picks up config changes without rerunning setup), pulls the image, `enable --now`s the unit.
- `destroy`: full teardown — disables/removes the unit and config symlink, force-removes any container.
- `status`: shows the systemd unit plus `birdc show protocols` (via `docker exec` — no host-side BIRD client needed).

**Dedicated FIB (`r9600` only):** `bird/conf/r9600.conf`'s `protocol kernel` writes BGP-learned routes into Linux table `100` (`kernel table 100;`) instead of main — but a kernel table with no `ip rule` pointing at it is never consulted. `bird/scripts/fib-ctl.sh setup|destroy|status` owns that missing piece, host-side, independent of the BIRD container:
- `setup`: registers `100 xdplab` in `/etc/iproute2/rt_tables.d/xdplab.conf` (name only, for `ip route show table xdplab`), then adds an unconditional `ip rule add lookup xdplab priority 500` so it's checked ahead of `main`.
- `destroy`: reverses both.
- Run before `bird-ctl.sh setup` on `r9600`; tear down in the reverse order.

**BGP session:** eBGP, directly connected — `r9600` and `r5500` are on the same L2 segment of `192.168.1.0/24`, so no `multihop` is needed; each side sets an explicit `source address` so the outgoing source IP is deterministic. ASNs: `64512` (`r9600`), `64513` (`r5500`) — private range, arbitrary choice.

---

## Non-Goals / Future Work

- The actual XDP forwarding program (`bpf_fib_lookup`, `DEVMAP`/`bpf_redirect`, ARP/neighbor handling) — separate design effort once infrastructure is live.
- LAN-wide BGP propagation beyond `r9600` ↔ `r5500`.

## Key Decisions Log

- **`r9600` ↔ `r5500` BGP rides the shared LAN**, not the XDP links — `r9600` has no host-visible interface on those links today (both ports VFIO-passed, [`vm/DESIGN.md`](vm/DESIGN.md)).
- **BGP-learned routes go straight into the kernel FIB** on both hosts — no custom BIRD-to-userspace-map syncing for the base routing layer.
- **`r9600` writes BGP-learned routes into a dedicated table (`100`/`xdplab`) + `ip rule`**, not the default/main table — keeps them separated from `r9600`'s normal LAN routing; owned by `bird/scripts/fib-ctl.sh`, independent of the BIRD container lifecycle (§1.3). `r5500` uses the default table — it's a dedicated router with no competing "normal" routing to separate from.
- **`rp_filter` fully disabled** on `r5500`, anticipating asymmetric/multi-path routing once BGP and any BGP-mode CNI are active.
- **systemd-networkd on `r5500`** after a split-brain with NetworkManager; NetworkManager remains on `r9600` (not causing conflicts there).
- **BIRD runs as a container** (`ghcr.io/cybozu/bird`), not a host package, on both hosts — pins the exact version identically across rebuilds; `--network host` + `NET_ADMIN` gives it the same kernel-FIB access a host install would have (§1.3).
- **BIRD's config/unit files live in-repo** (`bird/`), applied via one hostname-keyed script (`bird/scripts/bird-ctl.sh setup|destroy|status`) rather than manual per-machine `docker run`/systemd edits.
- **Link-endpoint addressing via DHCP + per-MAC static reservation** (`dnsmasq` on `r5500`), not config baked into whatever runs on the other end — keeps that side stock/swappable; `r5500` is the only host with L2 presence on both links.
