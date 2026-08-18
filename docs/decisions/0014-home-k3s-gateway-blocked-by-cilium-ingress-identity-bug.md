# 14. home-k3s Gateway is blocked by an upstream Cilium defect, not an Aegis misconfiguration

## Status

Accepted (documents a known limitation; no workaround adopted)

## Context

The Gateway/TLS/Observability milestone enabled Cilium's Gateway API on
`home-k3s` (CRDs, `gatewayAPI.enabled: true`, `hostNetwork.enabled: true`
— the same mechanism already proven on `dev-kind`). Cilium correctly
installs, the `GatewayClass` and `Gateway` reach `Accepted`+`Programmed`,
Envoy binds `:80`/`:443` on the node, and the `HTTPRoute` for `aegis-api`
is `Accepted`+`ResolvedRefs`. Every request through it, however, fails:

```
upstream connect error or disconnect/reset before headers.
reset reason: connection timeout
```

## Investigation

Live evidence, not assumption, at every step:

- **Not a NetworkPolicy issue.** The endpoint's `policy-enabled` was
  `none` (no policy at all). Adding the same
  `CiliumNetworkPolicy` (`fromEntities: [ingress]`) that `dev-kind`
  carries changed nothing; `cilium-dbg policy selectors` and the
  `policy-verdict` log both confirmed the rule correctly resolves and
  *allows* the connection at L3-L4.
- **Not UFW.** `ufw-user-input` already allows both pod (`10.42.0.0/16`)
  and service (`10.43.0.0/16`) CIDRs (the fix from ADR 0013's original
  bootstrap debugging). A live `dmesg`/`tcpdump` capture during a failing
  request showed **zero** UFW block log entries and zero packets on the
  `cilium_host` interface at all — Cilium's eBPF datapath handles this
  traffic entirely below the point UFW or a normal netdev capture can see
  it (`cilium-dbg monitor --type trace` was used instead).
- **The actual defect, isolated via `cilium-dbg monitor --type trace`
  and `cilium-dbg bpf ct list global`:** every connection tagged with
  the reserved `ingress` identity (Cilium's identity 8, assigned to
  Envoy's Gateway-proxied backend connections) gets a `SYN` out and a
  `SYN, ACK` back from the pod — and then nothing. No ACK ever
  completes the handshake; Envoy eventually times out and sends `RST`.
  An otherwise-identical connection from the same source IP tagged with
  the reserved `host` identity (identity 1 — ordinary host-network
  processes, e.g. kubelet probes) completes normally, every time,
  100% reproducible.
- **Ruled out as variables:** `routingMode: native` vs. `tunnel`
  (VXLAN) — both fail identically. `hostLegacyRouting: true` — no
  change. The `NET_BIND_SERVICE` capability added for port 80/443
  binding — irrelevant; the same failure reproduces on an unprivileged
  port (18080) with the capability removed entirely. Cilium's own
  feature detection (`cilium-dbg status --verbose`) is byte-for-byte
  identical between `dev-kind` (works) and `home-k3s` (fails) for
  `Socket LB`, `Masquerading`, and `KubeProxyReplacement` mode.
- **Cilium version:** reproduced identically on the pinned `1.20.0` and
  on a clean `1.17.18` install. A `1.16.7` test was attempted (one
  upstream GitHub reporter's confirmed-working version) but an
  in-place `helm upgrade` downgrade panicked the agent
  (`Unexpectedly Update() called for reconciliation` — a `statedb`
  reconciler incompatibility going backward across major versions, not
  informative about the actual bug). Recovered via `helm rollback`
  within minutes; no data or workload impact. A clean uninstall+install
  at 1.16.7 was considered but not pursued further given two versions
  already reproduced the identical symptom.
- **Matches known upstream reports**, none with a confirmed fix at the
  time of writing: cilium/cilium#36004 ("Gateway API on single node k0s
  causes connection timeout"), cilium/cilium#42325 ("connection timeout
  using Cilium Gateway API and httproutes" — same-node traffic,
  `host`-labeled ACKs), cilium/cilium#38100 (regression across 1.16→1.17
  for Ingress/GatewayAPI, no resolution documented).

The remaining plausible variable is the kernel: `cachyos` runs a very
recent kernel (`7.1.4-1-cachyos`) that `kind`'s node image does not
share. Confirming that would require kernel-level eBPF tracing
(`bpftool`, `bpftrace`) beyond what was pursued in this milestone.

## Decision

**Do not paper over this with a workaround that isn't actually
understood.** No NetworkPolicy, routing-mode change, or capability
tweak fixed it, and none is committed as a "fix" that doesn't fix
anything. `home-k3s` stays on Cilium `1.20.0` (matching `dev-kind`,
already proven for every other purpose on this cluster). The Gateway
API infrastructure — CRDs, `gatewayAPI` values, `cert-manager`, the
`Gateway`/`HTTPRoute` resources themselves — is committed and left in
place, since it is correctly configured and independently useful
groundwork; only the final Envoy→backend hop is broken.

TLS (cert-manager `Issuer`/`Certificate`) and observability
(Prometheus/Grafana behind the Gateway) are **not** implemented in this
milestone: the plan's own sequencing requires proving plain HTTP routing
before layering TLS on top of it, and that baseline never worked.

## Consequences

- `aegis-api` on `home-k3s` remains reachable only via
  `kubectl port-forward`, same as before this milestone.
- The Gateway, cert-manager, and CRD groundwork are real and reusable —
  a future attempt does not start from zero, only from "make the last
  hop work."
- Revisit when: a newer Cilium release changelog mentions a fix for
  reserved-identity same-node Gateway connections, or `cachyos`'s kernel
  changes (a kernel downgrade was not attempted — out of scope for this
  milestone, and a bigger intervention than the Gateway feature
  justifies on its own).
- No admission, network, or secret posture regressed: Kyverno, the
  existing `aegis-api` Deployment/Service, PostgreSQL, and the backup
  scheduler are all unaffected and were re-verified healthy after this
  investigation (including after an unplanned Cilium crash-loop during
  version testing, recovered via `helm rollback` with no data impact).

## Addendum: datapath isolation experiment

A follow-up milestone built a minimal control experiment
(`ingress-lab/`) to test whether the defect above is specific to
Cilium's Gateway/`reserved:ingress` datapath, or a more general
same-node forwarding problem on this host. An ordinary `nginx`
Deployment/Service (never touching Cilium's Gateway API) was proxied in
front of `aegis-api`, first pod-to-pod, then exposed via a plain K3s
`NodePort` — no TLS, no cert-manager, no MetalLB/Traefik/ingress-nginx,
no permanent architecture change.

**Result: both control paths worked, completely and deterministically.**

| Path | Backend source identity | TCP result | HTTP result |
|---|---|---|---|
| Cilium Gateway (`reserved:ingress` → `aegis-api`) | `ingress` (8) | SYN-ACK received, handshake never completes | 503, every request |
| Pod-to-pod control proxy (`ingress-lab-proxy` → `aegis-api`) | ordinary workload identity (`46914`) | completes cleanly (SYN, SYN-ACK, ACK, ACK, FIN) | 200 on `/healthz`, `/readyz`, `/api/v1/info`; 404 on `/metrics` |
| NodePort-exposed control proxy (external client → proxy → `aegis-api`) | `host` (1) → proxy; proxy (`46914`) → `aegis-api`, same as above | completes cleanly on both legs | 20/20 success on `/healthz`, `/readyz`, `/api/v1/info`; 20/20 correct 404 on `/metrics` |

Captured live via `cilium-dbg monitor --type trace` for every row —
not inferred. The proxy pod's own identity (an ordinary Kubernetes
Pod, not hostNetwork, not Cilium's Envoy) reaching `aegis-api` behaves
exactly like any other workload-to-workload connection on this cluster:
full handshake, clean close, every time, 20/20 external requests via
`NodePort` with zero failures across all three real paths.

**Hypothesis outcome**: **H1 supported — the defect localizes to the
Cilium Gateway `reserved:ingress` datapath specifically**, not to
same-node forwarding, `hostNetwork` proxying, or NodePort/K3s exposure
in general (H2 and H3 both refuted by this evidence: an ordinary pod
*and* the NodePort/host path both work cleanly). This does not confirm
the exact upstream root cause inside Cilium's Gateway implementation —
only that the failure is scoped to that one specific code path, not the
host, kernel, or Kubernetes networking stack more broadly.

This means `home-k3s` **can** expose `aegis-api` externally today via
an ordinary reverse-proxy workload + `NodePort` — that combination is
proven working, live, repeatedly. It was deliberately not adopted as
permanent infrastructure in this milestone: that is a real architecture
decision (proxy config ownership, TLS story, NetworkPolicy identity,
Authentik compatibility, dev-kind divergence) that deserves its own
milestone, not a side effect of a diagnostic experiment. The Gateway
resources from the original attempt are left exactly as they were —
broken, documented, not deleted — since Cilium's Gateway API remains
the long-term preferred mechanism if the upstream defect is ever fixed.

`ingress-lab/` is committed as a repeatable regression lab (see its own
`README.md`) rather than a one-off script, specifically so this
comparison can be re-run cheaply against a future Cilium release to
check whether the Gateway path starts working again — nothing about the
control experiment itself needs to change for that.
