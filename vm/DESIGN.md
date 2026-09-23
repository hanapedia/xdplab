# VM-Based Kubernetes on the Underlay

One way to run a workload on top of the [underlay network](../DESIGN.md): Talos VMs on `r9600`, each with whole-port VFIO passthrough of one physical XDP-link NIC port. Not the only way — kept under `vm/` and its own standalone [`vm/Taskfile.yml`](Taskfile.yml) so it's easy to ignore or drop once a lighter, non-VM approach exists. Underlay tasks (BIRD, dnsmasq, FIB) stay in the root `Taskfile.yml`, untouched by anything here.

- **`control-plane`** VM ↔ link 0 (`10.10.0.2/30`, gw `10.10.0.1`)
- **`worker`** VM ↔ link 1 (`10.10.1.2/30`, gw `10.10.1.1`)

No separate management/NAT NIC — the passed-through XDP NIC does double duty as both bootstrap/control-plane path and eventual data-plane path. `r9600` reaches both VMs via the underlay's BGP-learned routes; no separate management network needed.

---

## 1. `r9600` VFIO Setup

**IOMMU (AMD-Vi):** BIOS IOMMU/SVM enabled; kernel cmdline `iommu=pt` (`amd_iommu=on` is a no-op on AMD — AMD-Vi self-enables when present). Confirm via `dmesg | grep -i -E "AMD-Vi|iommu"` — look for `AMD-Vi: Interrupt remapping enabled` / `Virtual APIC enabled`, not just "detected". Each NIC port lands in its own IOMMU group (confirmed: groups 17, 18) — no ACS override patch needed.

**Bind to `vfio-pci`** (by PCI address, not vendor:device ID — both ports share the same ID):
```sh
lspci | grep -i ethernet                 # find the PCI slots
lspci -n -s 04:00.0; lspci -n -s 04:00.1 # device IDs
sudo modprobe vfio-pci

for dev in 0000:04:00.0 0000:04:00.1; do
  echo "$dev" | sudo tee /sys/bus/pci/devices/$dev/driver/unbind
  echo vfio-pci | sudo tee /sys/bus/pci/devices/$dev/driver_override
  echo "$dev" | sudo tee /sys/bus/pci/drivers_probe
done

lspci -k -s 04:00.0; lspci -k -s 04:00.1  # confirm
```

**Keep NetworkManager off these devices** via a udev rule keyed on PCI bus address (moot once bound to `vfio-pci` — the device leaves the `net` subsystem entirely — but keeps the interim state clean):
```
# /etc/udev/rules.d/99-vfio-nics-unmanaged.rules
SUBSYSTEM=="net", KERNELS=="0000:04:00.0", ENV{NM_UNMANAGED}="1"
SUBSYSTEM=="net", KERNELS=="0000:04:00.1", ENV{NM_UNMANAGED}="1"
```

**Persistence** — a oneshot systemd service re-binds both ports on every boot, before `libvirtd` starts:
```sh
sudo tee /usr/local/sbin/vfio-bind-x550.sh >/dev/null <<'EOF'
#!/bin/sh
set -e
modprobe vfio-pci
for dev in 0000:04:00.0 0000:04:00.1; do
  [ -e "/sys/bus/pci/devices/$dev/driver" ] && echo "$dev" > "/sys/bus/pci/devices/$dev/driver/unbind"
  echo vfio-pci > "/sys/bus/pci/devices/$dev/driver_override"
  echo "$dev" > /sys/bus/pci/drivers_probe
done
EOF
sudo chmod +x /usr/local/sbin/vfio-bind-x550.sh

sudo tee /etc/systemd/system/vfio-bind-x550.service >/dev/null <<'EOF'
[Unit]
Description=Bind X550 ports to vfio-pci
After=systemd-udev-settle.service
Before=libvirtd.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vfio-bind-x550.sh
RemainAfterExit=yes
Restart=on-failure
RestartSec=1
[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now vfio-bind-x550.service
```

**Restore the native `ixgbe` driver (debugging — e.g. testing a physical link with no VFIO/QEMU involved):**
```sh
sudo virsh destroy xdplab-control-plane; sudo virsh destroy xdplab-worker  # release the devices first
sudo systemctl disable --now vfio-bind-x550.service                        # so it doesn't reclaim them

for dev in 0000:04:00.0 0000:04:00.1; do
  echo "$dev" | sudo tee /sys/bus/pci/devices/$dev/driver/unbind
  echo "" | sudo tee /sys/bus/pci/devices/$dev/driver_override   # clear override, or the next probe rebinds vfio-pci
  echo "$dev" | sudo tee /sys/bus/pci/drivers_probe               # binds ixgbe via normal PCI ID matching
done
sudo ip link set enp4s0f0 up; sudo ip link set enp4s0f1 up
```
Back to VFIO when done: re-run `vfio-bind-x550.sh`, then `systemctl enable --now vfio-bind-x550.service` again.

---

## 2. VM Provisioning, OpenTofu

Config: [`terraform/`](terraform/). Provider: `dmacvicar/libvirt` (v0.9.x — full `libvirtxml` schema as nested attributes, not the older block style). Scope: VM domain/disk/pool resources only — not VFIO binding (§1) or IOMMU/BIOS/kernel-cmdline prerequisites.

**Per VM** (`libvirt_domain`, one per entry in `var.vms`): `q35` machine, UEFI/OVMF boot (`os.firmware = "efi"`, per-VM NVRAM), `cpu = { mode = "host-passthrough" }`, one PCI `hostdev` pinned to that VM's physical NIC (`0000:04:00.0` `control-plane`, `0000:04:00.1` `worker` — no separate virtual NIC), a virtio disk backed by a dedicated `libvirt_volume` (qcow2), and two cdroms: the Talos installer (`var.install_iso_path`, built via [`talos/scripts/build-installer-iso.sh`](talos/scripts/build-installer-iso.sh), not stock — see §3) and this node's own `metal-iso` config volume (`var.node_config_iso_paths[each.key]`, built via [`talos/scripts/build-node-config-iso.sh`](talos/scripts/build-node-config-iso.sh) from `talos/terraform`'s rendered output — one per node, not shared, since each carries a full config including that node's own secrets/hostname).

**Storage:** a dedicated `libvirt_pool` (`xdplab`, `dir` type), not libvirt's `default` — `dir` pools delete their backing storage on destroy, so `tofu destroy` fully wipes VM disks along with it.

---

## 3. Kubernetes Bootstrap (Talos)

**Prerequisites, all served from `r5500` since the VMs have no route to the public internet:**
- **Addressing** — DHCP with per-MAC static reservation (underlay, [`../DESIGN.md`](../DESIGN.md) §1.2) — `r5500` is the only host with L2 presence on both links (both `r9600` ports are VFIO-passed to the VMs).
- **NTP** — Talos blocks boot progression on successful NTP sync. `chrony`, host-installed on `r5500` (not containerized), serving both `/30`s via `allow` ACLs in `/etc/chrony/conf.d/xdplab-ntp-server.conf`. Each node's `.machine.time.servers` points at its own `/30` gateway.
- **Image pulls** — Talos needs its installer image plus every Kubernetes component image. Three pull-through caches (`registry:2`, one instance per upstream — a cache can only proxy one remote), containerized via a systemd template unit on `r5500`, host-networked so both `/30`s reach them at the same ports: `factory.talos.dev`→`:5000` (installer), `registry.k8s.io`→`:5001` (etcd, kube-apiserver, kube-scheduler, kube-controller-manager, coredns), `ghcr.io`→`:5002` (Talos's own vendored images, e.g. `siderolabs/kubelet` — a separate repo from `registry.k8s.io`). Config: [`regmirror/mirrors.conf`](regmirror/mirrors.conf) (`<name> <upstream> <port>`, one per line). Deployment: [`regmirror/xdplab-regmirror@.service`](regmirror/xdplab-regmirror@.service), a systemd template instance per mirror, pointed at its upstream via `REGISTRY_PROXY_REMOTEURL`/`REGISTRY_HTTP_ADDR` env vars (no config file — `registry:2` reads these directly), backed by a persistent bind mount so cached layers survive restarts. Control: `regmirror/scripts/regmirror-ctl.sh setup|destroy|status`, via this Taskfile's `regmirror:*`. Wired into Talos machine configs via `.machine.registries.mirrors` (`talos/terraform/machine_configs.tf`), one endpoint per node pointed at that node's own `/30` gateway.
- **Kernel module** — Talos ships `ixgbe` only as a loadable module and doesn't auto-probe it (confirmed on v1.14.1 and v1.13.10: `Interface: (none)` in the maintenance-mode TUI despite the module, its dependencies, and the correct PCI alias all present). Needs `.machine.kernel.modules: [{name: ixgbe}]` delivered before any network exists — solved via `talos.config=metal-iso` baked into the installer's kernel cmdline ([`talos/scripts/build-installer-iso.sh`](talos/scripts/build-installer-iso.sh)), reading a config volume ([`talos/scripts/build-node-config-iso.sh`](talos/scripts/build-node-config-iso.sh)) at boot, no network required.

**Config generation and delivery — [`talos/terraform`](talos/terraform):** a separate root module/state from `terraform/` (§2). `talos_machine_secrets` + one `talos_machine_configuration` data source per node render each node's complete machine config (`render.tf`, via `local_sensitive_file` to `talos/terraform/rendered/*.yaml`) — **not** applied live over the API (`talos_machine_configuration_apply`): Talos requires a complete, valid config (cluster CA present) before it'll accept anything from a metal-iso volume at all, and providing one makes it perform a full unattended install right there on first boot, so there's never a maintenance-mode window a live apply could target. `task talos:iso:config` builds each rendered file into that node's own metal-iso volume and deploys it to the libvirt pool; `task vm:setup` then boots the VMs off it, and they self-install/self-configure. `talos_machine_bootstrap` + `talos_cluster_kubeconfig` (`bootstrap.tf`/`kubeconfig.tf`, via `task talos:bootstrap`) target the resulting already-configured, reachable node — no Terraform-tracked dependency on the render step, since that hand-off happens out-of-band (VM boot + self-install). `task talos:teardown` tears the cluster + VMs down in the right order without touching the underlay.

**Talos 1.14 config gotcha:** many settings moved from the legacy `.machine`/`.cluster` fields to their own top-level documents (matched by `kind:`) — mixing a document with the legacy field it supersedes is rejected outright, silently past the TUI's default log view (use its `/` filter, e.g. search `occurred`, to surface the error). In `machine_configs.tf`/`locals.tf`: install goes through `kind: UnattendedInstallConfig` only, never `.machine.install.*` (its default disk selector, `disk.dev_path == "/dev/sda"`, never matches these VMs' virtio disk; both the disk selector and installer image must live in the *same* patch, since two patches sharing a `kind:` replace each other wholesale rather than merging). Hostname goes through `kind: HostnameConfig` with `auto: "off"` set alongside `hostname:` (never `.machine.network.hostname`; leaving `auto: stable` in place conflicts with an explicit `hostname:`). CNI is still Talos's default (flannel) — disabling it needs the auto-generated `KubeFlannelCNIConfig` document removed too (and `cluster.network.*` moves to its own `KubeNetworkConfig` document), not yet done.

**Bootstrap sequencing:**
1. VMs boot, DHCP their reserved `/30` addresses from `r5500`.
2. `r5500` routes `control-plane` ↔ `worker` traffic via plain kernel forwarding — sufficient for etcd/control-plane formation.
3. BIRD advertises the two `/30`s to `r9600` over BGP.
4. VMs self-install/self-configure from their own metal-iso volume (`task vm:setup`, after `task talos:iso:config`) — reachable from `r9600` via the BGP-learned routes.
5. `task talos:bootstrap` — bootstraps etcd, then fetches kubeconfig. Trivial quorum with a single control-plane node.

---

## 4. Kubernetes Core Components (CNI)

**Goal:** a CNI that participates in the BGP mesh, so pod CIDRs join the same routed fabric as the node `/30`s (Calico or Cilium BGP mode — final choice not made). The CNI starts a BIRD instance on each Talos node as part of its BGP-mode setup (not set up manually ahead of time); each peers with `r5500`'s to advertise that node's pod CIDR.

**Sequencing relative to XDP work:**
1. Install CNI with plain/default settings first — validate pod networking over the existing `/30` + kernel-forwarding path.
2. Enable the CNI's BGP mode.
3. **Only after this is stable**, introduce the custom XDP program on `r5500` (`bpf_fib_lookup`-based, replacing plain kernel forwarding for pod traffic) — intentionally sequenced last.

**Open question:** CNI install via Terraform (`helm_release`/`kubernetes` providers) vs. a manual/GitOps step post-bootstrap. Leaning Terraform-managed, not finalized.

---

## Non-Goals / Future Work

- Full SR-IOV/VF-based NIC sharing — currently whole-port passthrough, no VF splitting.

## Key Decisions Log

- **Whole-port VFIO passthrough**, not SR-IOV VFs — simpler, avoids VF driver/XDP-support uncertainty.
- **No separate management NIC** on VMs — single NIC serves bootstrap and data-plane; acceptable since the cluster is disposable and the underlay keeps `r9600` reachability robust regardless of VM data-plane state.
- **`talosctl`/Terraform run from `r9600`**, not a third machine — avoids extending BGP further into the LAN for now.
- **VM internet dependencies (NTP, image pulls) are served locally from `r5500`**, not by giving the VMs a real internet route — one pull-through cache per upstream registry handles every current and future image pull, rather than a real egress route or one-off fixes per unreachable registry.
- **`ixgbe` delivered via `metal-iso`**, not left to Talos's own auto-probing — verified Talos doesn't load it without this on v1.14.1 or v1.13.10, despite the module, its dependencies, and the correct PCI alias all present in the image.
- **Full machine configs are rendered to disk and delivered via per-node metal-iso volumes**, not applied live via `talos_machine_configuration_apply` — that resource needs a live-reachable maintenance-mode node, and none exists on this hardware: `ixgbe` needs a config to load, but any config valid enough for Talos to accept at all (cluster CA present) makes it perform a full unattended install immediately, closing the maintenance-mode window before a live apply could ever target it.
