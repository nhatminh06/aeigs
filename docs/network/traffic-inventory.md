# Traffic inventory — dev-kind

What actually talks to what on `dev-kind`, observed through Hubble rather
than read off the manifests. This exists so that when NetworkPolicy is
written, the allow rules come from evidence instead of guesswork.

**Three NetworkPolicies now exist**, covering ingress to Authentik's
PostgreSQL, server and worker (`security/authentik/networkpolicy-*.yaml`).
Everything else below is still unrestricted — no namespace-wide default
deny and no egress policy anywhere.

## Method

Cilium 1.20.0 runs the per-node Hubble server by default; this repository
additionally enables Hubble Relay (`scripts/bootstrap-cilium.sh`) to give
one queryable API across nodes.

Queried with the `hubble` CLI that ships inside the Cilium agent image, so
no extra binary is installed on the host:

```
POD=$(kubectl -n kube-system get pod -l k8s-app=cilium -o name | head -1)
RELAY=$(kubectl -n kube-system get svc hubble-relay -o jsonpath='{.spec.clusterIP}')
kubectl -n kube-system exec "${POD#pod/}" -c cilium-agent -- \
  hubble observe --server "${RELAY}:80" --from-namespace flux-system --last 200 -o compact
```

The agent runs in the host network namespace, so cluster DNS names do not
resolve from inside it — address Relay by its ClusterIP, not
`hubble-relay.kube-system.svc`.

Flows were produced by real activity: existing workloads, a forced
`flux reconcile source git flux-system`, a Grafana datasource query, and
short-lived `busybox:1.36.1` probe pods that were deleted afterwards.

Two things worth knowing before reading Hubble output here:

- The flow buffer is 4095 events and sits at 100% at roughly 40 flows/s,
  so history is about a minute and a half. Generate traffic, then query
  immediately.
- `10.244.0.201` shows as `(host)`. It is the node identity
  (`cilium-dbg ip list` → `reserved:host`), not a workload. Traffic from
  `kubectl port-forward` appears this way, which is easy to mistake for an
  application flow.

## Observed flows

| Source | Destination | Port/proto | Verdict | Classification |
|---|---|---|---|---|
| any pod | `kube-system/coredns` | 53/UDP | FORWARDED | REQUIRED |
| `demo-app/podinfo` client | `demo-app/podinfo` | 9898/TCP | FORWARDED | REQUIRED |
| `authentik/authentik-server` | `authentik/authentik-postgresql-0` | 5432/TCP | FORWARDED | REQUIRED |
| `observability/grafana` | `observability/prometheus-0` | 9090/TCP | FORWARDED | REQUIRED |
| `observability/prometheus-0` | node `172.18.0.2` | 10250, 9100, 6443/TCP | FORWARDED | PLATFORM |
| `observability/prometheus-0` | node `172.18.0.2` | 10249, 10257, 10259, 2381/TCP | FORWARDED | PLATFORM (see below) |
| `observability/prometheus-0` | `kube-system/coredns` | 9153/TCP | FORWARDED | PLATFORM |
| `flux-system/source-controller` | `20.205.243.166` (world) | 443/TCP | FORWARDED | REQUIRED |
| `flux-system/kustomize-controller` | node `172.18.0.2` | 6443/TCP | FORWARDED | REQUIRED |
| `demo-app` probe | `authentik/authentik-server` | 80→9000/TCP | `Policy denied DROPPED` | **BLOCKED BY NETWORKPOLICY** |
| `observability/grafana` | `authentik/authentik-server` | 9000/TCP | `policy-verdict:L3-L4 INGRESS ALLOWED` | REQUIRED (OIDC backend) |
| node (`reserved:host`) | `authentik/authentik-server` | 9000/TCP | FORWARDED | PLATFORM + DEVELOPMENT-ONLY |
| `demo-app` probe | `authentik/authentik-postgresql-0` | 5432/TCP | `Policy denied DROPPED` | **BLOCKED BY NETWORKPOLICY** |
| Gateway Envoy (`reserved:ingress`) | `authentik/authentik-server` | 9000/TCP | `policy-verdict:L3-L4 INGRESS ALLOWED` | REQUIRED (`auth.aegis.test`) |
| Gateway Envoy (`reserved:ingress`) | `observability/grafana` | 3000/TCP | FORWARDED (no policy selects Grafana) | REQUIRED (`grafana.aegis.test`) |

Why these classifications, rather than "it happened, so it is required":

- **REQUIRED** — the platform stops working without it. Remove DNS and
  nothing resolves; remove source-controller egress and GitOps stops;
  remove Grafana→Prometheus and dashboards are empty.
- **PLATFORM** — monitoring, not function. Blocking Prometheus scrapes
  loses visibility but the workloads keep running.
- **UNEXPECTED** — no component needs this path. It exists only because
  nothing prevents it.

Prometheus also scrapes `10249`, `10257`, `10259` and `2381`
(kube-proxy, controller-manager, scheduler, etcd). Those targets show as
down in Prometheus because kind does not expose them, but Hubble shows the
connection attempts are made and forwarded at L3/L4. Worth noting so a
future policy is not written against a target list that looks smaller than
the traffic actually is.

The `source-controller` destination `20.205.243.166` was confirmed as
GitHub by comparing it against `dig +short github.com`, which returns the
same address. It is recorded as an IP rather than a name because Hubble
identified it as `world` — DNS-based identity is not enabled here.

## Unexpected reachable paths

A throwaway pod in `demo-app` reached both `authentik-server` and, more
importantly, the Authentik **Postgres** on 5432 directly:

```
demo-app/lateral:45639 -> authentik/authentik-postgresql-0:5432
  policy-verdict:L4-Only INGRESS ALLOWED (TCP Flags: SYN)
```

Nothing in `demo-app` has any reason to speak to the identity database.
This is flat-network reachability: any compromised workload in any
namespace can currently open a TCP connection to the credential store.
Hubble reports the verdict as ALLOWED because there is no policy to
consult.

**Update — this path is now blocked.** It was the justification for the
first NetworkPolicy in Aegis. After enforcement the same probe records:

```
demo-app/pgdrop:32953 <> authentik/authentik-postgresql-0:5432
  policy-verdict:none INGRESS DENIED / Policy denied DROPPED
```

The original ALLOWED observation is kept above as the before-state.

A trap worth remembering: the Bitnami PostgreSQL subchart ships its own
NetworkPolicy allowing 5432 from any source. Because policies are
additive, the restrictive policy had no effect until that one was disabled
(`postgresql.primary.networkPolicy.enabled: false`). The probe still reached
the database with both policies present.

The second half of that trap took longer to find. The setting was first
written as `postgresql.networkPolicy.enabled`, one level too high — the
chart tests `.Values.primary.networkPolicy.enabled`, so Helm accepted the
value, ignored it, and still rendered the permissive policy. Nothing failed
at the time because the policy had also been deleted by hand, so the
boundary tested clean while its stated cause was doing nothing. The next
chart upgrade re-rendered the policy and the lab immediately failed on 5432.
A value that appears in `helm get values` has not necessarily been read by
the template that was supposed to consume it.

`demo-app -> authentik-server:80` was reachable after that milestone and
has since been blocked too:

```
demo-app/srvdrop:45772 <> authentik/authentik-server-7ff69cb7-...:9000
  policy-verdict:none INGRESS DENIED / Policy denied DROPPED
```

## Authentik server ingress map

Observed while Authentik ran normally, Grafana OIDC traffic was generated,
and probes continued:

| Source | Port | Evidence | Classification |
|---|---|---|---|
| `observability/grafana` | 9000 | 12 flows during OIDC backend calls; now `L3-L4 INGRESS ALLOWED` | REQUIRED APPLICATION |
| node (`reserved:host`) | 9000 | 81 flows; `cilium-dbg ip list` → `reserved:host` | PLATFORM (kubelet probes) + DEVELOPMENT-ONLY (port-forward) |
| `authentik-worker` | 9000 | none observed; no env var points at the server | NOT REQUIRED (excluded) |
| Prometheus | 9300 | none observed; server metrics port not scraped | NOT REQUIRED (excluded) |
| `demo-app` probe | 9000 | reachable before policy | UNEXPECTED → now blocked |

## Authentik worker ingress map

| Source | Port | Evidence | Classification |
|---|---|---|---|
| (none) | 9000, 9300 | no inbound flows in a window covering Flux reconciliation, a Grafana OIDC backend call, server activity and worker healthchecks — only a deliberate test probe appeared | NO LEGITIMATE INGRESS |
| `demo-app` probe | 9000, 9300 | both reachable before policy (`to-endpoint FORWARDED`) | UNEXPECTED → now blocked |

Four independent signals agree that nothing connects to the worker: no
Service selects it, its probes are `exec` (`ak healthcheck`) rather than
network, no ServiceMonitor/PodMonitor references it and Prometheus reports
**zero** authentik targets, and Hubble recorded no inbound flows.

It is still worth a policy. The worker **listens on 9000 and 9300**, and
because pod IPs are routable those ports were reachable from an unrelated
namespace even with no Service in front of them:

```
demo-app/wprobe -> authentik/authentik-worker-...:9000 to-endpoint FORWARDED
```

After a deny-all-ingress policy:

```
demo-app/wdrop <> authentik/authentik-worker-...:9000
  policy-verdict:none INGRESS DENIED / Policy denied DROPPED
```

Worth remembering: "no Service" does not mean "not reachable".

**Host traffic does not behave like pod traffic.** Cilium does not apply
pod ingress policy to traffic from the node's own identity, so kubelet
health probes keep working and `kubectl port-forward` still reaches the
server after enforcement — verified: probes pass (`Ready=True`, no new
restarts) and port-forward returns HTTP 200. This policy therefore does
**not** control user/browser access; it controls pod-to-pod access.

Grafana's `auth_url` is `localhost:9000`, reached by the browser through a
port-forward, so the interactive login redirect never traverses an
in-cluster path either. Only `token_url`/`api_url` (Grafana pod → server)
are policy-controlled.

## Gateway ingress path

Ingress now arrives through Gateway API rather than only `kubectl
port-forward`. The observed path is:

```
  external client (curl --resolve / browser)
        |
        v  host :80, forwarded by kind extraPortMappings
  Cilium Gateway Envoy  (host network)
        |
        v  backend connection carries reserved:ingress (identity 8)
  Grafana / Authentik server
```

The peer identity is the part worth recording, because it is not what the
source address suggests. Both of these were captured from the same address
in the same window:

```
10.244.0.241 (host)    -> authentik-server:9000  to-endpoint FORWARDED
10.244.0.241 (ingress) -> authentik-server:9000  policy-verdict:L3-L4 INGRESS ALLOWED
```

`cilium-dbg ip list` maps `10.244.0.241` to `reserved:host`, so reading the
address alone gives the wrong answer — an earlier revision of this document
did exactly that. `reserved:host` (identity 1) is kubelet probes and
port-forward; `reserved:ingress` (identity 8) is the Gateway's Envoy, and
only the latter is subject to pod ingress policy.

Consequences for policy:

- Workload peers stay in portable `networking.k8s.io/v1` NetworkPolicy.
- The Gateway peer requires `ciliumnetworkpolicy-server-gateway.yaml`,
  because `reserved:ingress` is assigned by the proxy datapath and no
  `podSelector`, `namespaceSelector` or `ipBlock` selects it. An `ipBlock`
  for the observed address was tested and the traffic was still dropped.
- Grafana has no NetworkPolicy selecting it, so its Gateway flow is
  forwarded without any rule. That is an absence of policy, not an allow.

This describes this Cilium version's Gateway implementation. Other Gateway
API implementations route through an ordinary pod and would be expressible
portably.

## Unknowns

- Only single-node behaviour is observed. `Connected Nodes: 1/1` is
  correct for this cluster but says nothing about cross-node flows.
- Traffic that did not happen during the observation window is missing —
  notably an interactive Grafana↔Authentik OIDC login, which was verified
  at the HTTP level previously but not captured as flows here.
- Egress is identified by IP only. Correlating an IP to a hostname needs
  DNS visibility that is not enabled.
- Hubble shows L3/L4. It says nothing about what is inside those
  connections.

## Policy implications

Done: PostgreSQL ingress (server + worker only) and server ingress
(Grafana only) are both isolated.

Still open, based on the evidence above and nothing more:

- A namespace-wide default deny is the remaining structural gap. All
  three current workloads are covered explicitly, so its value would be
  fail-closed behaviour for *future* pods rather than closing a known
  path — see the analysis in this milestone's report.
- The Gateway API controller cannot be expressed with an explicit `from:`
  entry on the server policy — an earlier version of this list predicted it
  could, and that prediction is wrong. Cilium's Gateway Envoy opens the
  backend connection under the `reserved:ingress` identity (identity 8),
  which is not `reserved:host` (1) even though both appear in Hubble as the
  same source IP, and which no `podSelector`, `namespaceSelector` or
  `ipBlock` can select. An `ipBlock` for that IP was tested and the traffic
  was still dropped. This is the difference between the two verdicts seen
  against the same address:

  ```
  10.244.0.241:41406 (host)    -> authentik-server:9000  to-endpoint FORWARDED
  10.244.0.241:52306 (ingress) <> authentik-server:9000  policy-verdict:none INGRESS DENIED
  ```

  Cilium documents `fromEntities: [ingress]` in a `CiliumNetworkPolicy` as
  the mechanism for this. That is a real departure from the portable-policy
  default and has not been adopted — see this milestone's report.
- Egress to DNS must be allowed everywhere, or everything breaks first.
- `source-controller` needs egress to the internet on 443; a policy that
  only considers in-cluster traffic will stop GitOps.
- Prometheus needs to reach node-level ports on the host IP, which is not
  a pod-selector relationship and needs different handling.
- Any future policy must check for pre-existing chart-shipped policies
  first. Additive semantics mean an existing permissive policy silently
  defeats a new restrictive one.
