# XDP Homelab — Infrastructure Design Doc

## Overview

Two physical machines connected via two direct point-to-point 10GbE links (native-XDP-capable NICs, `ixgbe` driver family — X540/X550). Goal: a disposable Kubernetes cluster (Talos on KVM/VFIO-passed-through NICs) as a testbed for BGP-based routing and, eventually, custom XDP forwarding (`bpf_fib_lookup`-based) accelerating pod-to-pod traffic across the two links.

- **`r9600`** — workstation/hypervisor. Hosts two Talos VMs, one per physical NIC port (VFIO passthrough, no port shared). Runs its own BIRD instance in its default netns. Has no host-visible interface on the XDP links themselves (both ports are passed to VMs) — its BIRD session rides the LAN instead.
- **`r5500`** — bare-metal router. Both NIC ports stay on the host. Runs BIRD (BGP) and, eventually, an XDP program doing FIB-based forwarding between the two links.

`r9600` and `r5500` also share an ordinary LAN subnet — the BGP session between them rides that LAN, not the XDP point-to-point links, which stay dedicated to VM ↔ `r5500` data traffic.

This is an experimentation environment, not a production system — rebuildability (`terraform destroy && apply`) is valued over hardening.

### Topology

```
r9600                                   r5500
┌─────────────┐                        ┌─────────────┐
│control-plane│ ── enp?s0f0 ───cable── │ enp1s0f0    │
│ 10.10.0.2   │      (VFIO)            │ 10.10.0.1   │
│    /30      │                        │    /30      │  ── BIRD (BGP) ──
├─────────────┤                        ├─────────────┤     + kernel FIB
│   worker    │ ── enp?s0f1 ───cable── │ enp1s0f1    │     forwarding
│  10.10.1.2  │      (VFIO)            │ 10.10.1.1   │     between the
│    /30      │                        │    /30      │     two links
└─────────────┘                        └─────────────┘
```

`r5500` holds the "younger" (`.1`) address on each `/30` — it's the router. `r9600` also runs `talosctl`; once BIRD advertises the two `/30`s, `r9600`'s kernel FIB gets routes to both VM addresses directly (no separate management network needed).

### Addressing

| Link | Subnet | `r5500` (router) | VM (`r9600` guest) |
|---|---|---|---|
| Link 0 | `10.10.0.0/30` | `10.10.0.1` (enp1s0f0) | `10.10.0.2` (`control-plane`) |
| Link 1 | `10.10.1.0/30` | `10.10.1.1` (enp1s0f1) | `10.10.1.2` (`worker`) |

| Host | LAN IP |
|---|---|
| `r9600` | `192.168.1.100` |
| `r5500` | `192.168.1.200` |

No separate management/NAT NIC on the VMs — the passed-through XDP NIC does double duty as both bootstrap/control-plane path and eventual data-plane path.

### BGP Mesh Overview

- **`r9600` ↔ `r5500`**: standard BGP (port 179) over the shared LAN, both in default netns. Unrelated to the XDP point-to-point links.
- **`r5500` ↔ VMs**: implicitly via `r5500`'s directly-connected `/30` routes, redistributed into BGP toward `r9600` (§1.2).
- **VMs ↔ `r5500` (later)**: once the CNI is installed, each Talos node runs its own BIRD instance (started by the CNI's BGP mode, e.g. Calico/Cilium) peering with `r5500` to advertise pod CIDRs — joining the same mesh (§4).

---

## 1. Host Setup

### 1.1 `r9600` (hypervisor)

**Hardware:** dual-port native-XDP NIC (Intel `ixgbe` family — X540-AT2 or X550; X550 preferred if the PCIe slot is natively `3.0 x4`, since X540 is speced for `2.1 x8` and X550 avoids relying on the bandwidth math working out).

**IOMMU (AMD-Vi):**
- BIOS: IOMMU/SVM mode enabled
- Kernel cmdline: `iommu=pt` (`amd_iommu=on` is a no-op on AMD — AMD-Vi self-enables when present)
- Confirm via `dmesg | grep -i -E "AMD-Vi|iommu"` — look for `AMD-Vi: Interrupt remapping enabled` / `Virtual APIC enabled`, not just "detected"

**IOMMU groups:** each NIC port lands in its own group (confirmed: groups 17, 18) — no ACS override patch needed:
```bash
find /sys/kernel/iommu_groups/ -type l | grep <pci-bus-prefix>
```

**VFIO binding (per port, by PCI address — not vendor:device ID, since both ports share the same ID):**
```bash
echo 0000:04:00.X > /sys/bus/pci/devices/0000:04:00.X/driver/unbind
echo vfio-pci > /sys/bus/pci/devices/0000:04:00.X/driver_override
echo 0000:04:00.X > /sys/bus/pci/drivers_probe
```
For persistence, if both ports are always destined for VMs: bind by vendor:device ID via `/etc/modprobe.d/vfio.conf` (`options vfio-pci ids=<vendor>:<device>`) plus `vfio-pci` in `/etc/modules` + `update-initramfs -u`.

**Keep NetworkManager off these devices** (active backend on `r9600`) via a udev rule keyed on PCI bus address:
```
# /etc/udev/rules.d/99-vfio-nics-unmanaged.rules
SUBSYSTEM=="net", KERNELS=="0000:04:00.0", ENV{NM_UNMANAGED}="1"
SUBSYSTEM=="net", KERNELS=="0000:04:00.1", ENV{NM_UNMANAGED}="1"
```
(Moot once bound to `vfio-pci` — the device leaves the `net` subsystem entirely — but keeps the interim state clean.)

**BIRD (BGP):**
- Peers with `r5500` over the LAN, imports the two `/30` routes into the kernel FIB — makes `talosctl` reachability from `r9600` "just work" once the session converges.
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

**DHCP (VM addressing, §3):** `dnsmasq`, containerized (image: [`dnsmasq/Dockerfile`](dnsmasq/Dockerfile), `ghcr.io/cybozu/ubuntu` base) — one instance bound to `enp1s0f0`/`enp1s0f1` only (`port=0`, no DNS role; never touches the LAN or loopback), handing out the two `/30` addresses as static per-MAC reservations (the VMs' *physical* NIC MACs, since VFIO passthrough preserves them) via `dhcp-range=...,static` + `dhcp-host=<mac>,<ip>` rather than baking config into VM boot media. Deployment: containerized via systemd, same pattern as BIRD (§1.3) but image is built locally rather than pulled, since there's no upstream registry for it. Config: [`dnsmasq/dnsmasq.conf`](dnsmasq/dnsmasq.conf). Control: `dnsmasq/scripts/dnsmasq-ctl.sh setup|destroy|status`.

**BIRD (BGP):**
- Peers with `r9600` over the LAN (port 179), both default netns.
- Must explicitly export directly-connected routes into BGP — `protocol direct` doesn't redistribute by default; needs an export filter for the two `/30`s.
- VM ↔ `r5500` traffic doesn't need BGP — that's plain kernel `ip_forward` between the two directly-connected subnets, active from day one regardless of BGP session state.
- Later, once the CNI is up, `r5500`'s BIRD also peers with each Talos VM's BIRD instance (started by the CNI's BGP mode) to learn pod CIDR routes — same process, additional peer sessions.
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

**Image:** [`ghcr.io/cybozu/bird:3.2.2.1`](https://github.com/cybozu/neco-containers/tree/main/bird) — minimal multi-stage build of upstream BIRD 3.2.2. `kernel` and `direct` are core BIRD protocols (not part of the image's trimmed `--with-protocols` list), so both remain available. Entrypoint `bird -f` runs in the foreground, so systemd manages it as a plain `Type=simple` service with logs going straight to journald — no detached mode, no log shipping.

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
- `--network host` — required, not just convenient: BIRD must see the host's real interfaces/routes (`protocol direct` on `r5500`) and write BGP-learned routes into the *host* kernel FIB on both ends.
- `--read-only` + `--cap-drop ALL`, re-adding only `NET_ADMIN` (kernel FIB), `NET_RAW`/`NET_BIND_SERVICE` (BGP socket). `tmpfs` at `/run/bird` gives BIRD a writable spot for its control socket/PID file despite the read-only root.
- Config is bind-mounted from a fixed host path rather than baked into the image — same image on both hosts, config is the only variable.

**systemd unit:** `Type=simple` wrapping the foreground `docker run` above; `Requires=docker.service`, `After=network-online.target`, `Restart=on-failure`. `ExecStartPre` force-removes any stale container and attempts a `docker pull` (prefixed `-`, so an offline reboot falls back to the cached image instead of failing to start). `ExecStop` sends `docker stop` for a clean BGP session teardown.

**`bird/scripts/bird-ctl.sh setup|destroy|status`:**
- Uses the local hostname (`r9600`/`r5500`) directly as the config key; override with `XDPLAB_HOST` if a machine is renamed/reimaged.
- `setup`: symlinks `bird/conf/<hostname>.conf` → `/etc/xdplab/bird/bird.conf` and `bird/bird-bgp.service` → `/etc/systemd/system/` (symlinked, not copied, so `git pull` + `systemctl restart bird-bgp` picks up config changes without rerunning setup), pulls the image, `enable --now`s the unit.
- `destroy`: disables/removes the unit and config symlink, force-removes any container — full teardown per the disposable/rebuildable philosophy.
- `status`: shows the systemd unit plus `birdc show protocols` (via `docker exec` — `birdc`/`birdcl` ship inside the image, no host-side BIRD client needed).

**Dedicated FIB (`r9600` only):** `bird/conf/r9600.conf`'s `protocol kernel` writes BGP-learned routes into Linux table `100` (`kernel table 100;`) instead of main — but a kernel table with no `ip rule` pointing at it is never consulted. `bird/scripts/fib-ctl.sh setup|destroy|status` owns that missing piece, host-side, independent of the BIRD container:
- `setup`: drops `100 xdplab` into `/etc/iproute2/rt_tables.d/xdplab.conf` (name registration only, for `ip route show table xdplab`; the table itself needs no explicit creation — it appears once BIRD writes a route into it), then adds a single unconditional `ip rule add lookup xdplab priority 500` (no destination match) so `xdplab` is checked ahead of `main`.
- `destroy`: removes the rule, flushes table `xdplab`, removes the name registration.
- Run before `bird-ctl.sh setup` on `r9600` (the rule just needs to exist by the time BIRD's session converges and starts writing routes); tear down in the reverse order.

**BGP session:** eBGP, directly connected — `r9600` and `r5500` are on the same L2 segment of `192.168.1.0/24`, so no `multihop` is needed; each side sets an explicit `source address` so the outgoing source IP is deterministic rather than left to the OS's routing-table pick. ASNs: `64512` (`r9600`), `64513` (`r5500`) — private range, arbitrary choice.

---

## 2. VM Provisioning (`r9600`), OpenTofu

Config: [`terraform/`](terraform/). Provider: `dmacvicar/libvirt` (v0.9.x rewrite — full `libvirtxml` schema coverage as nested attributes, not the older block style).

**Scope boundary:** manages VM domain/disk/pool resources only — not VFIO binding (§1.1) or IOMMU/BIOS/kernel cmdline prerequisites.

**Per VM** (`libvirt_domain`, one per entry in `var.vms`): `q35` machine, UEFI/OVMF boot (`os.firmware = "efi"`, per-VM NVRAM), `cpu = { mode = "host-passthrough" }`, one PCI `hostdev` pinned to that VM's physical NIC (`0000:04:00.0` `control-plane`, `0000:04:00.1` `worker` — no separate virtual NIC), a virtio disk backed by a dedicated `libvirt_volume` (qcow2), and two cdroms: the Talos installer (`var.install_iso_path`, built via [`talos/scripts/build-installer-iso.sh`](talos/scripts/build-installer-iso.sh) — not stock, see §3) and a shared `metal-iso` config volume (`var.kernel_module_config_iso_path`, built via [`talos/scripts/build-node-config-iso.sh`](talos/scripts/build-node-config-iso.sh)).

**Storage:** a dedicated `libvirt_pool` (`xdplab`, `dir` type) rather than libvirt's own `default` pool — `dir` pools delete their backing storage on destroy by default, so `tofu destroy` fully wipes VM disks along with it.

**Optional follow-on:** the `siderolabs/talos` provider could generate/apply Talos machine configs declaratively — separate provider/concern, not adopted yet.

---

## 3. Kubernetes Bootstrap (Talos)

**Networking prerequisite:** each VM needs a stable IP on its sole (VFIO-passed) interface before `talosctl` can reach it. Addressing is handled by DHCP with a per-MAC static reservation, served from `r5500` (§1.2) — `r5500` is the only machine with actual L2 presence on both point-to-point links (both physical ports on `r9600` are VFIO-passed straight into the VMs, so `r9600` itself has none).

**Kernel module prerequisite:** Talos ships `ixgbe` (confirmed present in the squashfs, correct PCI alias for `0x1563`, all three module dependencies present) but only as a loadable module (`CONFIG_IXGBE=m`) — Talos does not auto-probe it the way it does built-in drivers, so the X550 never becomes a network device on a stock boot (`Interface: (none)` in the maintenance-mode TUI, confirmed both on v1.14.1 and v1.13.10). It needs `.machine.kernel.modules: [{name: ixgbe}]` delivered before any network exists, which has the same chicken-and-egg problem as addressing did — solved the same way: `talos.config=metal-iso` baked into the installer's kernel cmdline ([`talos/scripts/build-installer-iso.sh`](talos/scripts/build-installer-iso.sh)), reading the directive from a filesystem-labeled `metal-iso` volume ([`talos/scripts/build-node-config-iso.sh`](talos/scripts/build-node-config-iso.sh), patch: [`talos/patches/kernel-modules.yaml`](talos/patches/kernel-modules.yaml)) at boot, no network required. Unlike addressing, this directive is identical for every VM, so one config volume is shared across all of them rather than built per-node.

**Target config:** `control-plane` `10.10.0.2/30` gw `10.10.0.1`; `worker` `10.10.1.2/30` gw `10.10.1.1`.

**Bootstrap sequencing:**
1. VMs boot, DHCP their reserved `/30` addresses from `r5500`.
2. `r5500` routes `control-plane` ↔ `worker` traffic via plain kernel forwarding (already active, §1.2) — sufficient for etcd/control-plane formation.
3. BIRD on `r5500` advertises the two `/30`s to `r9600` over BGP → `r9600`'s kernel FIB gets routes to both VMs.
4. Run `talosctl` from `r9600` — reachable via the BGP-learned routes, no separate management network.
5. Standard Talos bootstrap: apply machine configs, `talosctl bootstrap`, wait for etcd quorum — trivial with a single control-plane node, no witness/3rd node needed.

**Note:** control-plane traffic (etcd, kube-apiserver, kubelet registration) rides the same `/30`-routed path throughout — decoupled from XDP development risk by design.

---

## 4. Kubernetes Core Components (CNI)

**Goal:** a CNI that participates in the BGP mesh, so pod CIDRs join the same routed fabric as the node `/30`s (Calico or Cilium BGP mode — final choice not made).

**BIRD on the VMs:** the CNI starts a BIRD instance on each Talos node as part of its BGP-mode setup (not set up manually ahead of time). Each node's BIRD peers with `r5500`'s to advertise that node's pod CIDR, joining the `r9600` ↔ `r5500` LAN session and the node-level `/30` routes.

**Sequencing relative to XDP work:**
1. Install CNI with plain/default settings first — validate pod networking over the existing `/30` + kernel-forwarding path.
2. Enable the CNI's BGP mode so each node's BIRD peers with `r5500` and pod CIDRs get advertised/learned.
3. **Only after this is stable**, introduce the custom XDP program on `r5500` (`bpf_fib_lookup`-based, replacing plain kernel forwarding for pod traffic) — the actual research payload, intentionally sequenced last.

**Open question:** how much stays in Terraform — CNI install via Terraform (`helm_release`/`kubernetes` providers) for full declarative reproducibility, vs. a manual/GitOps step post-bootstrap. Leaning Terraform-managed, consistent with the rest of the design, but not finalized.

---

## Non-Goals / Future Work

- The actual XDP forwarding program (`bpf_fib_lookup`, `DEVMAP`/`bpf_redirect`, ARP/neighbor handling) — separate design effort once infrastructure is live.
- LAN-wide BGP propagation beyond `r9600` ↔ `r5500` — `talosctl` runs from `r9600` directly, which already has the needed routes.
- Full SR-IOV/VF-based NIC sharing — currently whole-port passthrough, no VF splitting.

## Key Decisions Log

- **Whole-port VFIO passthrough**, not SR-IOV VFs — simpler, avoids VF driver/XDP-support uncertainty.
- **No separate management NIC** on VMs — single NIC serves bootstrap and data-plane; acceptable since the cluster is disposable and BGP keeps `r9600` reachability robust regardless of VM data-plane state.
- **`talosctl` runs from `r9600`**, not a third machine — avoids extending BGP further into the LAN for now.
- **`r9600` ↔ `r5500` BGP rides the shared LAN**, not the XDP links — `r9600` has no host-visible interface on those links (both ports VFIO-passed).
- **BGP-learned routes go straight into the kernel FIB** on both hosts — no custom BIRD-to-userspace-map syncing for the base routing layer.
- **`r9600` writes BGP-learned routes into a dedicated table (`100`/`xdplab`) + `ip rule`**, not the default/main table — keeps them separated from `r9600`'s normal LAN routing; owned by `bird/scripts/fib-ctl.sh`, independent of the BIRD container lifecycle (§1.3). `r5500` uses the default table — it's a dedicated router with no competing "normal" routing to separate from.
- **`rp_filter` fully disabled** on `r5500`, anticipating asymmetric/multi-path routing once BGP and the CNI's BGP mode are active.
- **systemd-networkd on `r5500`** after a split-brain with NetworkManager; NetworkManager remains on `r9600` (not causing conflicts there).
- **BIRD runs as a container** (`ghcr.io/cybozu/bird`), not a host package, on both hosts — pins the exact version identically across rebuilds; `--network host` + `NET_ADMIN` gives it the same kernel-FIB access a host install would have (§1.3).
- **BIRD's config/unit files live in-repo** (`bird/`), applied via one hostname-keyed script (`bird/scripts/bird-ctl.sh setup|destroy|status`) rather than manual per-machine `docker run`/systemd edits.
- **VM addressing via DHCP + per-MAC static reservation** (`dnsmasq` on `r5500`), not config baked into VM boot media — keeps install ISOs stock/swappable across distros; `r5500` is the only host with L2 presence on both links.
- **`ixgbe` kernel module delivered via `metal-iso`**, not left to Talos's own auto-probing — verified Talos doesn't load it without this on either v1.14.1 or v1.13.10, despite the module, its dependencies, and the correct PCI alias all being present in the image. Independent of and orthogonal to the DHCP-addressing decision above — this is about the driver existing at all, not about IP assignment.
