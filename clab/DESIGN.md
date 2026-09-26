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

`cluster.kind.yaml` carries kubeadm patches (`kubeletExtraArgs.node-ip`, `localAPIEndpoint.advertiseAddress`) so each node's Kubernetes-visible address is its physical XDP-link address (`10.10.0.2`/`10.10.1.2`) rather than kind's docker-bridge address — same pattern `mooring/e2e_v2`'s `network/cluster.kind.yaml` uses. The address doesn't exist on `node0` yet at the moment kubelet first reads this (`mover`'s move happens concurrently, not strictly before), but kubelet tolerates that and picks it up once the interface appears. `taints: []` on the control-plane's `InitConfiguration` drops the default `node-role.kubernetes.io/control-plane:NoSchedule` taint, so both nodes are schedulable — only two nodes total, no dedicated control-plane capacity to protect.

## Giving nodes real NICs

Each X550 port stays bound to `ixgbe` throughout — no VFIO.

- **Why not VFIO:** a container shares the host kernel and has no driver of its own to take over a VFIO device — VFIO only makes sense for VMs or userspace data planes like DPDK.
- **Why not a containerlab link type:** containerlab has no link type that moves a physical NIC in, and its `macvlan` link type would only allow generic-mode XDP, not native.
- **How the move happens:** a kind node's own `exec:` can't do it — the NIC isn't visible inside a netns it hasn't been moved into yet. Instead, one extra containerlab node (`mover`) with `network-mode: host` ([containerlab docs](https://containerlab.dev/manual/network/#host-mode-networking) — attaches the container straight to the host's own network namespace) runs the move as a `stages.configure.exec` command ([`mover/move.sh`](mover/move.sh)), so it's part of `containerlab deploy` itself. It looks up the target kind node's PID via the docker socket (bind-mounted in) to reach into its netns.

**Addressing — DHCP before the move, not after.** Moving an interface to a different netns flushes its addresses and admin-up state. Rather than adding a DHCP client into the (otherwise minimal) kind node image, `move.sh` gets the address the normal way first, while the port is still in the host netns, then re-applies the same learned address/gateway once it's moved:

```bash
ip link set <port> up
dhclient -1 <port>                    # one-shot: get a lease from r5500's dnsmasq and exit, no persistent daemon
ADDR=$(ip -o -4 addr show <port> | awk '{print $4}')
GW=$(ip route show dev <port> | awk '/default/ {print $3}')

PID=$(docker inspect -f '{{.State.Pid}}' <node-container>)
ip link set <port> netns $PID          # address is flushed by the move
docker exec <node-container> ip link set <port> name node0
docker exec <node-container> ip addr add "$ADDR" dev node0   # re-apply the lease we already learned
docker exec <node-container> ip link set node0 up             # must come before the route below, or it fails
docker exec <node-container> ip route replace default via "$GW" dev node0
```

Keeps `dnsmasq`'s existing per-MAC reservations on `r5500` completely unchanged — the physical MAC doing the DHCP request is the same either way, whether that request comes from the host or a container.

**Teardown — move the port back to the host netns first** ([`mover/restore.sh`](mover/restore.sh), via `task stop`/`task restore-nics`). `exec:` has no destroy-time equivalent, so this is a separate, explicit step run before `containerlab destroy`, not folded into the topology the way the move itself is. Runs directly on the host, unlike `move.sh` — plain `/proc` access, no `network-mode: host` or docker-socket bind-mount needed. A real device does fall back to the host's netns on its own if this step is skipped, rather than being deleted, but not cleanly (kernel-assigned name, a leftover altname blocking rename-back) — `restore.sh` leaves it in the same state (renamed, addresses clear) either way.

## BGP in each node's netns

Each kind node runs its own BIRD instance, in the *same* netns as the node — not a sidecar the node talks to, but a second container sharing its network stack via containerlab's `network-mode: container:<ext-container-name>` (the pattern from `mooring/e2e_v2`'s `tor0`/node BIRD containers). Since the physical port was moved into that same netns, BIRD sees it directly and peers with `r5500` over the real link — no separate management path, no virtual ToR:

```yaml
control-plane:
  network-mode: container:xdplab-control-plane   # same netns as the kind node -- kind's own container name
  kind: linux
  image: xdplab-bird:local
  binds:
    - bird/control-plane.conf:/etc/bird/bird.conf
  stages:
    create:
      wait-for:
        - node: mover
          stage: configure   # node0 must actually be in place before bird starts
```

`mover`'s own NIC-move commands live under `stages.configure.exec` rather than the plain top-level `exec:` for exactly this reason — top-level `exec:` isn't tied to a named stage another node can `wait-for`, only per-stage `exec` is.

This is exactly what [`bird/conf/r5500.conf`](../bird/conf/r5500.conf) already anticipates ("*Later: additional `protocol bgp` blocks peer with each Talos VM's own BIRD instance... joining the same mesh*") — for `clab/`, that "later" is immediate, not deferred to a CNI's BGP mode. `r5500` gains one eBGP peer per node, direct-connected like its existing `r9600` session, no `multihop`. Each node gets its own ASN, not `r9600`'s (`64512`) — `control-plane` is `64514`, `worker` is `64515`, continuing on from the pair (`64512`/`64513`) the LAN session already uses:

```
protocol bgp 'control-plane' {   # quoted -- BIRD doesn't allow hyphens in bare identifiers
  local as 64513;
  neighbor 10.10.0.2 as 64514;
  direct;
  passive;
  ipv4 { import all; export all; };
}
protocol bgp 'k8s-worker' {   # not `worker` -- collides with a BIRD 3.x reserved symbol even quoted (mooring/e2e_v2 hits the same thing)
  local as 64513;
  neighbor 10.10.1.2 as 64515;
  direct;
  passive;
  ipv4 { import all; export all; };
}
```

`export all;` here means each kind node learns the *other* node's pod CIDR back through `r5500`, not just the two link `/30`s -- necessary since the two kind nodes have no direct link to each other, only point-to-point links to `r5500`. A node doesn't re-import its own route reflected back to it: standard eBGP AS-path loop prevention, no explicit filter needed since each node has its own ASN. `r5500`'s next hop for a reflected route (originally received with the *other* node's own address as `bgp_next_hop`, unreachable from the far side) gets automatically substituted with `r5500`'s own address on the receiving side's link -- BIRD does this without an explicit `next hop self` for a `direct` eBGP session whose received next hop isn't in the local interface's subnet.

Each node's own config is the mirror image:

```
# control-plane
router id 10.10.0.2;
protocol bgp r5500 {
  local 10.10.0.2 as 64514;
  neighbor 10.10.0.1 as 64513;
  direct;
  ipv4 { import all; export all; next hop self; };
}
```
```
# worker
router id 10.10.1.2;
protocol bgp r5500 {
  local 10.10.1.2 as 64515;
  neighbor 10.10.1.1 as 64513;
  direct;
  ipv4 { import all; export all; next hop self; };
}
```

Static per-node files (`bird/control-plane.conf`, `bird/worker.conf`), same as `r9600.conf`/`r5500.conf` at the repo root — no templating here either.

## Operational notes

- A physical port can belong to only one namespace at a time, so there is one port per node container.
- A node container restart destroys its netns, which falls the port back to the host namespace same as the teardown case above — the move (and DHCP) script has to run again afterward, not only at initial deploy.
- `r5500`'s BIRD can get stuck reporting `Idle, Error: Link down` for the `control-plane`/`k8s-worker` sessions even once the link is genuinely back up (`LOWER_UP` confirmed on both ends) — a stale device-scan state, not a real link problem. `sudo systemctl restart bird-bgp.service` on `r5500` clears it; restarting the kind-side BIRD sidecars alone doesn't (the stale state is on `r5500`'s side).
- A `bird.conf` edit on `r9600`/`r5500` needs `task bird:reload` (or `task bird:reload:r9600`/`:r5500` individually), not just a file sync: both `bird-ctl.sh setup`'s `enable --now` (a no-op if already active) and `birdc configure` inside the running container re-read the container's own bind-mounted view of the file, which stays pinned to the old inode once rsync replaces it (write-new-then-rename) -- only a full container restart re-resolves the bind mount against the current file.

## CNI: Coil and Cilium

Both, not a single final choice — same two options `mooring/e2e_v2` already exercises, with its install tasks imported and adapted (kind cluster name, `node0` as the physical-link device, fresh ASNs): [`coil/Taskfile.yaml`](coil/Taskfile.yaml), [`cilium/Taskfile.yaml`](cilium/Taskfile.yaml), wired into [`Taskfile.yml`](Taskfile.yml) (`task coil:install`, `task cilium:install`). Both integration points live in the per-node BIRD config itself ([`bird/control-plane.conf`](bird/control-plane.conf), [`bird/worker.conf`](bird/worker.conf)), ported from `mooring/e2e_v2`'s node configs minus their `gateway recursive` + custom next-hop import filter on the outward session — that exists to resolve next-hops through their shared-L2/single-AS ToR fabric, which a plain point-to-point `/30` doesn't need. The outward `r5500` session does still carry `local`/`direct`/`next hop self` (mooring's loopback-sourced route needs its next hop rewritten; Coil/Cilium's routes already have a legitimate one, so this is a no-op for them). Neither Coil nor Cilium talks BGP to `r5500` directly — both hand pod-route advertisement to BIRD instead, via different mechanisms:

- **Coil** doesn't speak BGP at all — `coild` programs pod routes straight into Linux kernel table `119` itself (plus its own `ip rule` making that table authoritative for pod traffic, the same "dedicated kernel table + rule" shape already used for `r9600`'s own FIB, [`../DESIGN.md`](../DESIGN.md) §1.3). BIRD picks those routes up read-only with `protocol kernel 'coil' { kernel table 119; learn; ... }`, merges them into its main table via a `protocol pipe`, and they ride out through BIRD's existing `r5500` session (`export all;`, unfiltered — same as `mooring/e2e_v2`'s outward session).
- **Cilium** runs its own BGP speaker and peers with BIRD over loopback (`127.0.0.1`) — a second, local-only BGP session distinct from BIRD's outward one to `r5500`, on its own ASN pair (`64516` Cilium / `64517` BIRD) so it can't collide with the real per-node ASNs (`64514`/`64515`) or `r5500`'s (`64513`). Cluster-wide `CiliumBGPClusterConfig`, no node selector — unlike `mooring/e2e_v2`'s rack-labeled subset, both of xdplab's nodes need it.
- **Neither's routes get double-installed locally.** Both are only supposed to reach the kernel routing table through their own mechanism (`coild`'s own table `119`; Cilium's native routing / BPF redirect, not a kernel route at all) — BIRD re-advertising them to `r5500` is a separate concern from BIRD installing them into *this* node's own kernel table. So the exclusion filter lives on the **local** `protocol kernel` block's export (`if proto = "coil" then reject; if (64516, 64517) ~ bgp_community then reject;` — Cilium-learned routes are community-tagged on import specifically so this filter can recognize them), not on the `r5500` session, which stays `export all;` unfiltered — same split `mooring/e2e_v2`'s configs use.

## `domestic0`/`domestic1` test targets (`r5500`)

Same role and addressing as `mooring/e2e_v2`'s `domestic0`/`domestic1` (`network/cluster.clab.yaml.tmpl`) — "external" endpoints to test egress/BGP-advertised-route correctness against, without spinning up throwaway pods each time. `r5500` *is* the router here (unlike the reference, where a separate `router0` node fills that role), so these are plain docker containers on `r5500` itself: [`domestic/domestic-ctl.sh`](domestic/domestic-ctl.sh) wires each one to `r5500` with a direct point-to-point veth pair (`--network none`, manually addressed — same shape as `move.sh`, avoiding Docker's own bridge/NAT), plain L3 routing rather than a bridge — each subnet only ever has this one container on it, so there's no L2 segment worth switching. `domestic0` (`ghcr.io/cybozu/ubuntu-debug:24.04`, `192.168.0.100/24`) is a generic client target; `domestic1` (`ghcr.io/cybozu/testhttpd:0`, `192.168.10.100/24`) serves HTTP. `r5500` holds `.101` on each veth's host end — no BGP advertisement needed for `r5500` to reach them, they're directly connected. Installed via `task domestic:setup`/`task domestic:destroy` (`clab/Taskfile.yml`, rsynced to `r5500` the same way as `bird/`/`dnsmasq/`), persisted across reboots by [`xdplab-domestic.service`](domestic/xdplab-domestic.service) (oneshot, same pattern as `vm/DESIGN.md`'s `vfio-bind-x550.service`).

Each target only accepts forwarded traffic sourced from `10.70.0.1/32` (`domestic-ctl.sh`'s `ALLOWED_SRC`) — the mooring-managed NAT/egress-gateway address below — via a per-target ACCEPT/DROP pair on Docker's `DOCKER-USER` chain (matched on the target's host-side veth as `-o`). Anything else routed in, including pod traffic sourced from the pod CIDR, is dropped before it reaches the container; this only affects forwarded traffic, so `r5500`'s own locally-originated traffic to either target (via `OUTPUT`, not `FORWARD`) is unaffected.

## Mooring egress NAT gateway

[`hanapedia/mooring`](https://github.com/hanapedia/mooring) — an XDP-based SNAT/reverse-NAT egress gateway — installed and wired in the same shape as `mooring/e2e_v2`'s own `install-mooring` task: [`mooring/Taskfile.yaml`](mooring/Taskfile.yaml) (`task mooring:install`), CRDs and manifests copied from `mooring/manifests/` (`crds/`, `operator.yaml`, `agent.yaml`). Runs on top of whichever CNI (Coil or Cilium) is already installed — install that first. Unlike Coil/Cilium's own Taskfiles, mooring's operator/agent images aren't built here: `mooring:install` assumes `ghcr.io/hanapedia/mooring-operator:dev`/`ghcr.io/hanapedia/mooring-agent:dev` already exist locally (built from the `mooring` repo directly) and only `kind load docker-image`s them in.

`mooring-agent` runs as a DaemonSet on every node (`NODE_IFACE=node0`) and, like Cilium, speaks BGP to the local BIRD over loopback rather than to `r5500` directly — a third passive session (`protocol bgp mooring`, ASN pair `64518` agent / `64519` BIRD, on `127.0.0.2` this time, not `127.0.0.1`) in [`bird/control-plane.conf`](bird/control-plane.conf)/[`bird/worker.conf`](bird/worker.conf), community-tagged and excluded from the local kernel export the same way Coil/Cilium are. `xdplab-worker` carries the `mooring.hanapeida.link/advertise: "true"` node label (`cluster.kind.yaml`); mooring only advertises the NAT external IP from a node carrying that label.

[`mooring/natconfig.yaml`](mooring/natconfig.yaml) is the one `NATConfig` in use: pods labeled `app: domestic1-client` get SNATed to `10.70.0.1/32` for traffic toward `192.168.0.0/24`/`192.168.10.0/24` (`domestic0`/`domestic1`'s subnets) — matching `domestic-ctl.sh`'s `ALLOWED_SRC` exactly, so only mooring-SNATed traffic can reach either target. [`mooring/sample/`](mooring/sample/) has two `domestic1-client` pods, one per node (`task sample:apply`) — `xdplab-worker`'s is the fast path (client and NAT gateway co-located), `xdplab-control-plane`'s is the slow path (cross-node). `task mooring:exec CMD=...` runs `moorctl` on every agent pod.

Perf tasks (`clab/Taskfile.yml`, ported from `mooring/e2e_v2`'s `perf-*` tasks) drive `iperf3` between the sample pods and `domestic0`: `task perf:mooring` runs the full fast/slow, big/small-packet sweep (`task perf:server-start`/`perf:server-stop` control `domestic0`'s `iperf3 -s`, over SSH since `domestic0` lives on `r5500` rather than alongside the kind cluster like the reference's own `domestic0`).

The mooring-learned route (`10.70.0.1/32`, sourced from the agent's loopback with no real path to it) relies on the outward `r5500` session's `local`/`direct`/`next hop self` (above) to get a usable next hop -- without it, BIRD derives a self-referential one that `r5500` rejects (`Invalid NEXT_HOP attribute`). No per-route filter override is needed beyond that. Confirmed reaching `r5500` and both kind nodes correctly.

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
