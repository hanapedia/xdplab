# xdplab

A disposable, BGP-underlay Kubernetes homelab for experimenting with native XDP.

Two machines, two direct 10GbE links:

- **`r9600`** — hypervisor/workstation, runs two Talos VMs (one per NIC port, VFIO passthrough)
- **`r5500`** — bare-metal router, both NIC ports stay on the host

BGP (BIRD) is the underlay: `r9600` ↔ `r5500` over the LAN today, extending to each Talos node once the CNI's BGP mode is up.

- [DESIGN.md](DESIGN.md) — underlay design (BGP mesh, DHCP addressing)
- [vm/DESIGN.md](vm/DESIGN.md) — VM-based Kubernetes on the underlay (VFIO, Talos)
- [clab/DESIGN.md](clab/DESIGN.md) — kind + containerlab on the underlay, no VMs (draft)
- [SPEC.md](SPEC.md) — hardware, interfaces, addressing
