# Machine A: kind + containerlab

An alternative to [`vm/`](../vm/) for running Kubernetes on the [underlay](../DESIGN.md): kind nodes as plain containers instead of Talos VMs, each given a real physical NIC port instead of a VFIO-passed one. No IOMMU, no OVMF/UEFI, no libvirt, no custom Talos install media — a container already shares the host kernel, so a port just needs to move into its netns. Trades VM-level isolation for that simplicity.

`Machine A` here is `r9600`, `Machine B` is `r5500` — same physical machines, same LAN, same `r9600` ↔ `r5500` BGP session and dedicated FIB table as the rest of this repo ([`../DESIGN.md`](../DESIGN.md) §1.1/§1.3), all reused unchanged. Once a physical port is moved into a container's netns it disappears from `r9600`'s default netns exactly as it does under VFIO, so nothing about `r9600`'s own BIRD/FIB setup changes.

## Addressing

Same two `/30`s as the rest of the repo ([`../DESIGN.md`](../DESIGN.md) §Addressing) — `r5500` holds `.1` on each, the kind node holds `.2`:

| Link | Subnet | `r5500` | kind node |
|---|---|---|---|
| Link 0 | `10.10.0.0/30` | `10.10.0.1` | `control-plane` — `10.10.0.2` |
| Link 1 | `10.10.1.0/30` | `10.10.1.1` | `worker` — `10.10.1.2` |

kind's own control-plane traffic (etcd, API server, kubelet↔apiserver) stays on kind's default docker-bridge network, untouched — the X550 ports are dedicated to BGP-routed data-plane traffic, same division of concerns as `vm/`'s point-to-point links.

## Kind cluster topology (containerlab)

- The kind cluster is deployed through containerlab's `k8s-kind` node kind, with the kind cluster config passed as `startup-config`.
- Each kind node is additionally declared as an `ext-container` so containerlab can wire links to it and run `exec` commands inside it. An `ext-container` node's name in the topology must be the container's *actual* existing name — kind names its own containers `<cluster-name>-<role>`, not containerlab's usual `clab-<topology-name>-<node-name>`, since containerlab didn't create it.
- Kind cluster name: `xdplab` (so the two node containers are `xdplab-control-plane`, `xdplab-worker`) — containerlab topology name: `xdplab` too, for consistency, though the two aren't required to match.

Two fixed nodes with fixed addresses — no templating layer (`.tmpl` + generator task) needed for the topology file itself; a static `cluster.clab.yaml` is simpler and sufficient here. (Contrast with `vm/talos/terraform`, which *does* template — Talos configs are large, secret-bearing, generated documents, a different scale of problem than a handful of static container definitions.)

## Giving nodes real NICs

Each X550 port stays bound to `ixgbe` throughout — no VFIO.

- **Why not VFIO:** a container shares the host kernel and has no driver of its own to take over a VFIO device — VFIO only makes sense for VMs or userspace data planes like DPDK.
- **Why not a containerlab link type:** containerlab has no link type that moves a physical NIC in, and its `macvlan` link type would only allow generic-mode XDP, not native.
- **How the move happens, declaratively:** a kind node's own `exec:` can't do it — the NIC isn't visible inside a netns it hasn't been moved into yet. Instead, one extra containerlab node with `network-mode: host` ([containerlab docs](https://containerlab.dev/manual/network/#host-mode-networking) — attaches the container straight to the host's own network namespace) runs the move as its `exec:` block. `exec` commands run once, right after that node finishes booting, as part of `containerlab deploy` itself — no separate script to remember to run afterward. It still needs the target kind node's PID to move the port into (e.g. `docker inspect -f '{{.State.Pid}}' xdplab-control-plane`), which means either the docker socket bind-mounted into this node's image or some other PID lookup — not yet nailed down.

**Addressing — DHCP before the move, not after.** Moving an interface to a different netns (`ip link set <dev> netns <pid>`) flushes its addresses — the kernel treats addresses/routes as scoped to a namespace, so they don't carry across. Rather than adding a DHCP client into the (otherwise minimal) kind node image, get the address the normal way first, while the port is still easy to reach from the host:

```bash
ip link set <port> up
dhclient -1 <port>                    # one-shot: get a lease from r5500's dnsmasq and exit, no persistent daemon
ADDR=$(ip -o -4 addr show <port> | awk '{print $4}')
GW=$(ip route show dev <port> | awk '/default/ {print $3}')

PID=$(docker inspect -f '{{.State.Pid}}' <node-container>)
ip link set <port> netns $PID          # address is flushed by the move
docker exec <node-container> ip link set <port> name eth1
docker exec <node-container> ip addr add "$ADDR" dev eth1   # re-apply the lease we already learned
docker exec <node-container> ip route replace default via "$GW" dev eth1
docker exec <node-container> ip link set eth1 up
```

Keeps `dnsmasq`'s existing per-MAC reservations on `r5500` completely unchanged — the physical MAC doing the DHCP request is the same either way, whether that request comes from the host or a container. **To verify empirically:** that address flush on netns-move is really what happens on this kernel/driver (documented general behavior, not yet confirmed on this hardware) — if addresses do survive the move, this simplifies to a plain DHCP request with no learn-then-reapply step.

**Teardown — move the port back to the host netns first.** Linux is expected to fall back a *real* device (unlike a virtual one such as veth) to the host's initial netns automatically if its current netns is destroyed while still holding it, rather than deleting it — but that's relying on implicit kernel behavior for a physical port, worth avoiding. `exec:` has no destroy-time equivalent (it only ever runs once, right after deploy), so this can't be folded into the topology the way the move itself can — it has to be a separate, explicit step (rename back, `ip link set <port> netns 1` or equivalent) run before `containerlab destroy`, e.g. from a Taskfile task, so the port's fate is deterministic and observable either way.

## BGP in each node's netns

Each kind node runs its own BIRD instance, in the *same* netns as the node — not a sidecar the node talks to, but a second container sharing its network stack via containerlab's `network-mode: container:<ext-container-name>` (the pattern from `mooring/e2e_v2`'s `tor0`/node BIRD containers). Since the physical port was moved into that same netns, BIRD sees it directly and peers with `r5500` over the real link — no separate management path, no virtual ToR:

```yaml
control-plane:
  network-mode: container:xdplab-control-plane   # same netns as the kind node -- kind's own container name
  kind: linux
  image: bird:3.2.2.1-xdplab
  binds:
    - bird/control-plane.conf:/etc/bird/bird.conf
```

This is exactly what [`bird/conf/r5500.conf`](../bird/conf/r5500.conf) already anticipates ("*Later: additional `protocol bgp` blocks peer with each Talos VM's own BIRD instance... joining the same mesh*") — for `clab/`, that "later" is immediate, not deferred to a CNI's BGP mode. `r5500` gains one eBGP peer per node, direct-connected like its existing `r9600` session, no `multihop`. Each node gets its own ASN, not `r9600`'s (`64512`) — `control-plane` is `64514`, `worker` is `64515`, continuing on from the pair (`64512`/`64513`) the LAN session already uses:

```
protocol bgp control-plane {
  local as 64513;
  neighbor 10.10.0.2 as 64514;
  ipv4 { import all; export filter { if net ~ [ 10.10.0.0/30, 10.10.1.0/30 ] then accept; reject; }; };
}
protocol bgp worker {
  local as 64513;
  neighbor 10.10.1.2 as 64515;
  ipv4 { import all; export filter { if net ~ [ 10.10.0.0/30, 10.10.1.0/30 ] then accept; reject; }; };
}
```

Each node's own config is the mirror image:

```
# control-plane
router id 10.10.0.2;
protocol bgp r5500 {
  local as 64514;
  neighbor 10.10.0.1 as 64513;
  ipv4 { import all; export all; };  # export narrows to the pod CIDR once Coil/Cilium is wired in, see "CNI" below
}
```
```
# worker
router id 10.10.1.2;
protocol bgp r5500 {
  local as 64515;
  neighbor 10.10.1.1 as 64513;
  ipv4 { import all; export all; };
}
```

Static per-node files (`bird/control-plane.conf`, `bird/worker.conf`), same as `r9600.conf`/`r5500.conf` at the repo root — no templating here either.

## Operational notes

- A physical port can belong to only one namespace at a time, so there is one port per node container.
- A node container restart destroys its netns, which falls the port back to the host namespace same as the teardown case above — the move (and DHCP) script has to run again afterward, not only at initial deploy.

## CNI: Coil and Cilium

Both, not a single final choice — same two options `mooring/e2e_v2` already exercises, with its install tasks imported and adapted (kind cluster name, `eth1` as the physical-link device, fresh ASNs): [`coil/Taskfile.yaml`](coil/Taskfile.yaml), [`cilium/Taskfile.yaml`](cilium/Taskfile.yaml), wired into [`Taskfile.yml`](Taskfile.yml) (`task coil:install`, `task cilium:install`). Neither talks BGP to `r5500` directly — both hand pod-route advertisement to the node's own BIRD instance from §"BGP in each node's netns" instead, just via different mechanisms:

- **Coil** writes pod routes into a dedicated Linux kernel table; BIRD picks them up with a `protocol kernel 'coil' { learn; ... }` reading that table, merges them into its main table via a `protocol pipe`, and they ride out through BIRD's existing eBGP session to `r5500`. No BGP speaker in Coil itself — the same "dedicated kernel table, picked up by a rule/pipe" shape already used for `r9600`'s own FIB ([`../DESIGN.md`](../DESIGN.md) §1.3), just Coil populating the table instead of BIRD's own `ip rule`.
- **Cilium** runs its own BGP speaker and peers with BIRD over loopback (`127.0.0.1`) — a second, local-only BGP session distinct from BIRD's outward one to `r5500`, on its own ASN pair (`64516` Cilium / `64517` BIRD) so it can't collide with the real per-node ASNs (`64514`/`64515`) or `r5500`'s (`64513`). BIRD then re-advertises whatever it learns there out through its `r5500` session, same as Coil's routes. Cluster-wide `CiliumBGPClusterConfig`, no node selector — unlike `mooring/e2e_v2`'s rack-labeled subset, both of xdplab's nodes need it.

## Future work

### SR-IOV VFs

- Create VFs on the X550 ports and give one to each node container (or pod, or VM). This allows more nodes than physical ports.
- Nodes run native XDP on their VF, subject to the `ixgbevf` limits: redirect support, MTU with XDP loaded, no zero-copy AF_XDP.
- Traffic between VFs on the same port is switched inside the NIC. Use separate VLANs per VF to force it through Machine B.
- Set `spoofchk off` and `trust on` on a VF if its node needs extra MACs or promiscuous mode.

### Host XDP demux over veths

- Keep the PFs on Machine A's host with full `ixgbe` XDP. A native XDP program redirects frames through a devmap into per-node veth pairs.
- veth supports native XDP, so nodes can still attach their own programs. On many kernels, the container end needs an XDP program loaded (or veth GRO enabled) for redirected frames to be accepted.
- The return path uses XDP on the host-side veths, redirecting out through the PF.
- Routed /31s on the veths, looked up with `bpf_fib_lookup`, avoid broadcast and ARP handling and match Machine B's design.
- containerlab's `host` link type creates these veths, which makes the topology fully declarative. Capacity is limited only by CPU.
