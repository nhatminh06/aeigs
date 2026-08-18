# 13. Persistent home-k3s environment

## Status

Accepted

## Context

`dev-kind` has proven the platform's full engineering loop — GitOps,
policy, supply chain, SLO/incident response — but it is deliberately
disposable, and teaches nothing about persistent control-plane state,
host lifecycle, reboots, or environment promotion. This adds a **second**
environment, `home-k3s`, on a real persistent Linux host, without
migrating or destabilizing `dev-kind`.

The target host is a personal laptop (`cachyos`, CachyOS/Arch, reachable
over Tailscale) — a **persistent-state** environment, not a
**persistent-uptime** one. It can be unreachable when the laptop sleeps
or is closed. This is stated plainly rather than described as anything
resembling a home server SLA.

## Decision

### Single node, K3s v1.36.3+k3s1

One node, no HA — deliberate for Phase 1, which studies persistence, not
Kubernetes HA. `v1.36.3+k3s1` was confirmed live from K3s's own channel
API (`update.k3s.io/v1-release/channels`) to be both the current `stable`
and `latest` channel head at the time of this decision, and its
Kubernetes version (v1.36.3) is close to `dev-kind`'s pinned `v1.36.1`.

### K3s built-in components

| Component | Decision | Why |
|---|---|---|
| Flannel | Disabled (`flannel-backend: none`) | Cilium owns the CNI. |
| K3s's NetworkPolicy controller | Disabled (`disable-network-policy: true`) | Cilium enforces `NetworkPolicy`; a second enforcement path is redundant, not additive. |
| Traefik | Disabled (`disable: [traefik]`) | Aegis standardizes on Cilium Gateway API for HTTP routing; running two ingress systems buys nothing. |
| kube-proxy | Disabled (`disable-kube-proxy: true`) | Not the original plan — see "What changed during implementation" below. |
| ServiceLB, local-path-provisioner, metrics-server | Left at K3s defaults | No reason to remove a working built-in; Gateway exposure is explicitly out of scope for Phase 1, and local-path is likely useful for the next (storage) milestone. |

### Cilium: SHARED / DEV-KIND-ONLY / HOME-K3S-ONLY

Cilium 1.20.0 (same version as `dev-kind`, already documented there as
e2e-tested against Kubernetes 1.36 — the same minor K3s runs here).
`bootstrap/cilium/home-k3s-values.yaml` is a deliberately separate file
from `bootstrap/cilium/values.yaml`, not a shared base — two small,
readable files rather than composition, same judgment this repo already
applies elsewhere (see "Two explicit small values files may be clearer
than clever composition" reasoning threaded through this decision).

| Value | dev-kind | home-k3s | Why they differ |
|---|---|---|---|
| `ipam` | `mode: kubernetes` (leans on kind's own per-node PodCIDR) | `ipam.operator.clusterPoolIPv4PodCIDRList: ["10.42.0.0/16"]` | K3s's node IPAM doesn't provide the same per-node assignment kind does; this follows Cilium's own official K3s install guide instead, pinned to K3s's default pod CIDR. |
| `kubeProxyReplacement` | `true` (required by Cilium's Gateway API implementation) | `true` | Both true, but for different immediate reasons — see below. |
| `gatewayAPI` | `enabled: true` | not set (chart default: disabled) | No Gateway on home-k3s in Phase 1. |
| `hubble.relay` | `enabled: true` | not set (chart default) | Not needed to prove persistent-cluster lifecycle; not added for parity. |
| `operator.replicas` | `1` | `1` | Same reason both places: single node, the chart's anti-affinity default would leave a second replica `Pending` forever. |
| `devices`, `routingMode`, `MTU` | not needed (kind nodes are Docker containers, one predictable interface) | `devices: wlan0`, `routingMode: native`, `MTU: 1500` | Real host, multiple interfaces — see below. |

### What changed during implementation (evidence, not assumption)

The original plan left K3s's kube-proxy running and deferred
`kubeProxyReplacement` until home-k3s might need a Gateway. That did not
work in practice:

1. **kube-proxy + Cilium coexistence broke Service ClusterIP routing from
   the pod network.** `curl` to `10.43.0.1:443` succeeded from a
   `hostNetwork` pod but hung indefinitely from an ordinary pod; CoreDNS
   sat `0/1 Ready` forever, unable to sync against the API server.
   Switching to full kube-proxy-replacement (`disable-kube-proxy: true`
   on the host, `kubeProxyReplacement: true` in Cilium) — Cilium's own
   documented "Kubernetes Without kube-proxy" mode, and what `dev-kind`
   already runs — fixed this.
2. **Cilium's device/MTU auto-detection picked up the wrong interface.**
   This host also has a Tailscale interface (MTU 1280) and a `docker0`
   bridge alongside the real LAN interface (`wlan0`, MTU 1500). Cilium's
   auto-detection initially included `tailscale0` as a routing device and
   inherited its MTU cluster-wide. Restricting `devices` to `wlan0` and
   setting `MTU: 1500` explicitly (both confirmed against the live host,
   not guessed) fixed it. `dev-kind` never hits this because kind's nodes
   are Docker containers with exactly one predictable interface.
3. **A host firewall (UFW) was silently dropping traffic Cilium needed.**
   Even after (1) and (2), pod-to-ClusterIP traffic still failed. UFW's
   `INPUT` chain has a default-deny policy, and once Cilium's eBPF
   datapath translates a pod's request to a ClusterIP into a request to
   the node's own IP (the mechanism kube-proxy-replacement uses), that
   packet becomes "traffic destined to this host" — exactly what a
   default-deny `INPUT` policy blocks, with nothing in UFW's default
   rule set anticipating a pod subnet. Fixed with two scoped allow rules
   (`ufw allow from 10.42.0.0/16` and `.../10.43.0.0/16`, the pod and
   Service CIDRs) rather than disabling UFW or weakening its `INPUT`
   policy generally. `dev-kind` never hits this either — `kind`'s Docker
   Desktop networking doesn't put a host firewall between pods and the
   API server the way a real Linux desktop's default security posture
   does.
4. **Single node, no second node to tunnel to** — switched
   `routingMode` from the chart's default VXLAN overlay to `native`,
   removing a layer of complexity with no benefit here.

None of this was bundled in "because Cilium on a real host might need
it" — each change was made only after a specific, observed failure, and
is recorded here so a future rebuild doesn't have to rediscover it.

### Flux: consumer, not a second writer

`home-k3s` runs only `source-controller`, `kustomize-controller`,
`helm-controller`, `notification-controller` (`flux install --export`
without `--components-extra`) — no `image-reflector-controller`, no
`image-automation-controller`. There is no `ImageRepository`,
`ImagePolicy`, `ImageUpdateAutomation`, or Git write credential of any
kind on this cluster. `dev-kind` remains the only environment that
discovers and writes `aegis-api` releases into this repository — running
two independent writers against the same Git history was rejected
outright, not evaluated as a tradeoff.

`GitRepository/flux-system` here reads anonymously, same as `dev-kind`'s
(`docs/decisions/0009-minimize-runtime-git-credentials.md`) — verified
live, not assumed.

### Application: manual promotion, not automation

`apps/aegis-api/home-k3s/deployment.yaml` pins an explicit
`tag@digest` — currently `v0.1.5`, the release already validated through
`dev-kind`'s full pipeline (Trivy, SBOM, Cosign, Kyverno, and the SLO
incident-response lab). Moving this to a newer release is always a
deliberate human Git commit, made only after that release has been
through `dev-kind`'s loop — never automatic, and there is no controller
capable of changing it automatically even if someone wanted to.

### Application manifests: duplicated, not composed

`apps/aegis-api/home-k3s/` is an independent, small set of manifests
(`namespace.yaml`, `deployment.yaml`, `service.yaml`), not a base/overlay
refactor of the existing `apps/aegis-api/` directory. `deployment.yaml`
and `service.yaml` are near-identical to `dev-kind`'s (only the image
digest and the removed Gateway-routing label differ). A base/overlay
split was considered and rejected for the same reason the Cilium values
weren't shared: two small, rarely-changing files are more readable than
composition for exactly two consumers, and this way the existing,
already-proven `dev-kind` directory is never touched — zero refactor risk
to it. Revisit if a third environment needs this application.

### Kyverno: included, reused as-is

`security/kyverno/` and all 3 existing `ClusterPolicy` objects
(`disallow-latest-tag`, `disallow-privileged-containers`,
`verify-aegis-api-image`) are deployed here unchanged — persistent
deployment should not weaken artifact trust just because it's a newer
environment. Wired with `dependsOn` (`kyverno` → `kyverno-policies` →
`aegis-api`) so the signature policy exists before the application's
Kustomization applies.

### Kubeconfig access: `write-kubeconfig-mode: "644"`

K3s writes `/etc/rancher/k3s/k3s.yaml` mode `600` (root-only) by default.
Setting `write-kubeconfig-mode: "644"` in the persistent host config
(applied before the first start, not patched in after) lets the operator
fetch it over SSH without a second `sudo` round-trip. **Tradeoff, stated
plainly:** this makes a cluster-admin credential file readable by any
local user on the host. Accepted here because this is a single-user
personal machine; revisit — narrower permissions, or a dedicated
low-privilege kubeconfig — if that ever changes.

## Alternatives considered

**Talos, RKE2, kubeadm.** Explicitly out of scope for this milestone —
K3s alone is enough new infrastructure to learn from; a distribution
comparison is a deliberate later exercise, not a default reached for now.

**A Multipass VM on this Mac**, considered when no reachable physical
host was confirmed yet. Rejected once `cachyos` (a real, existing,
Tailscale-reachable personal machine) was confirmed reachable — a real
host teaches real host lifecycle; a VM on the same laptop running Aegis's
own tooling would not.

## Consequences

- `home-k3s`'s Cilium configuration is real host-specific knowledge
  (device names, firewall interaction) that will not transfer verbatim
  to a different physical host — expected and accepted; the next
  persistent host (if any) gets this same investigation, not a blind
  copy of these values.
- UFW's `INPUT` policy now explicitly trusts the pod and Service CIDRs.
  This is scoped to those two ranges, not a general firewall weakening.
- Single point of failure: when this laptop is off, sleeping, or
  disconnected, `home-k3s` and everything on it is unavailable. There is
  no HA and none is claimed.
- Environment comparison:

| Property | dev-kind | home-k3s |
|---|---|---|
| Lifecycle | Disposable | Persistent |
| Primary use | Experiment, failure injection, policy development | Long-lived validation |
| Image updates | Automated (Flux Image Automation) | Manual promotion (human Git commit) |
| Git write credential | Present (`aegis-api-image-writer`) | None |
| CNI | Cilium | Cilium |
| Gateway / TLS | Yes | Not yet |
| Monitoring | Yes (Prometheus/Grafana, SLO rules) | Not yet |
| Persistence | Cluster lifecycle only (rebuild is cheap) | Host-backed K3s state (survives service restart and full reboot, proven live) |
| Application data | Ephemeral | Still stateless in Phase 1 |
