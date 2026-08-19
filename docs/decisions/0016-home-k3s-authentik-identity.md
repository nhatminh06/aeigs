# 16. home-k3s runs its own persistent Authentik, not a copy of dev-kind's

## Status

Accepted

## Context

home-k3s needed identity — Grafana behind real authentication instead
of a local admin account — but dev-kind's Authentik (chart `2026.5.6`,
`security/authentik/helmrelease.yaml`) is built around being disposable:
its PostgreSQL is the chart's bundled Bitnami subchart with
`persistence.enabled: false`, explicitly not meant to survive a
cluster rebuild. home-k3s is the opposite kind of environment —
persistence and recovery are the point — so identity state needed the
same standard this project already holds PostgreSQL to elsewhere
(`stateful-lab/postgresql/`): its own instance, its own PVC, its own
backup, provable across a real reboot.

## PostgreSQL: standalone, not the bundled subchart

Confirmed directly from the chart (`helm pull` + template search, not
assumed): no template wires `AUTHENTIK_POSTGRESQL__*` env vars to the
bundled subchart specifically — they're pure `global.env` passthrough,
the same mechanism dev-kind already uses for
`AUTHENTIK_POSTGRESQL__PASSWORD`. Pointing at an external database is
not a workaround or an unsupported configuration; it's the identical
code path with the connection details supplied explicitly instead of
implicitly defaulting to the subchart's Service name. This confirmed
the milestone's own default bias (standalone PostgreSQL) rather than
assuming it.

`security/authentik/home-k3s/postgresql-statefulset.yaml` mirrors
`stateful-lab/postgresql/statefulset.yaml`'s already-proven pattern
almost line for line (same `postgres:17-alpine` digest, same
`runAsUser: 999`/`fsGroup: 999` reasoning) — a completely separate
instance, namespace `authentik`, own generated credentials, never
shared with stateful-lab's or dev-kind's.

## Ingress and NetworkPolicy: an architectural difference from dev-kind, not forced symmetry

dev-kind's Authentik needs a `CiliumNetworkPolicy` exception
(`security/authentik/ciliumnetworkpolicy-server-gateway.yaml`) because
Cilium's Gateway Envoy opens the backend connection under the
`reserved:ingress` identity, which no portable `NetworkPolicy` selector
can match. home-k3s's ingress (ADR 0015) is an ordinary nginx
Deployment — confirmed live via `cilium-dbg monitor --type trace` that
its connection to `authentik-server` carries a normal workload
identity, clean handshake, no Cilium exception needed. A single
portable `networking.k8s.io/v1` `NetworkPolicy` covers both the browser
path (via the ingress) and Grafana's own backend OIDC calls. This is
recorded as genuine evidence of how the two environments' ingress
architectures differ, not as a decision to make policy "match" dev-kind
for its own sake.

## The DB-only identity invariant

The whole point of this milestone is distinguishing what Git/Flux
recovers from what only the database recovers. A non-admin test
identity (`aegis-recovery-test`) was created through Authentik's own
API — **never** declared in the Grafana OIDC blueprint, never in Git —
specifically so a successful recovery proves database persistence, not
blueprint reapplication. The blueprint (Grafana's OAuth provider/
application) is Git-owned, same as dev-kind's; the test user is
deliberately not.

## Real defects found and fixed live (not hypothetical)

- **OAuth redirect hung indefinitely**: `root_url`, `auth_url`, and the
  provider's `redirect_uri` all omitted home-k3s's NodePort (`:30443`)
  — every one defaulted to the browser's implicit port 443, which has
  nothing listening. Fixed by making the port explicit everywhere a
  hostname appears.
- **Authentik's frontend failed with "the request failed and the
  interceptors did not return an alternative response"**: nginx's
  `$host` variable strips the port from the `Host` header it forwards;
  `$http_host` preserves whatever the browser actually sent. Without
  it, Authentik's own frontend JS built API calls against the implicit
  port 443 and every one failed silently before reaching nginx.
- **Blueprint mounted but never applied**: the worker's
  `blueprints_discovery` task was enqueued on pod start but never
  executed (no "Task started" ever logged for it, unlike other
  periodic tasks that ran normally). Worked around with a direct `ak
  apply_blueprint` invocation; not fully root-caused. See the runbook's
  "if the blueprint doesn't apply automatically" section.
- **`kubectl exec -i` broke on Authentik's larger PostgreSQL dump**:
  reproduced consistently in isolation (`connection reset by peer` /
  `broken pipe` over the Tailscale path once stdin+stdout duplex
  streaming involved a few MB, not the few KB stateful-lab's dump
  is) — worked around in both backup scripts by `kubectl cp`-ing the
  plaintext dump into the pod's own `/tmp` first and exec-ing against
  that local path instead.
- **Prometheus crash-looped under WAL-replay CPU contention**: the
  operator's default liveness probe (3s timeout, ~30s failure budget)
  was too tight for this 12-core host under load — a real, sustained
  loop (17 restarts, hundreds of readiness failures over several
  hours), not a one-off. Fixed with a `containers:` strategic-merge
  override relaxing both probes, verified against the rendered
  `Prometheus` CR before applying.

## Consequences

- home-k3s's Grafana authenticates through Authentik with a real,
  environment-specific OAuth client (own client_id/secret, never
  dev-kind's), local admin login kept as a documented recovery
  fallback.
- Authentik identity state (users, the OAuth application/provider) is
  now covered by the same off-host encrypted backup model as
  stateful-lab, with its own verified backup and scratch-restore proof.
  Destructive Authentik PostgreSQL restore (PVC/PV loss, not just Pod
  loss) was proven live on 2026-08-19 — see
  `docs/runbooks/home-k3s-authentik.md`'s "Destructive identity
  recovery". Empty-replacement-host Authentik reconstruction (mirroring
  stateful-lab's own "Second proof") has **not** been attempted.
- Blueprint discovery's unreliable automatic trigger is a real,
  disclosed operational gap — an operator restoring `authentik-blueprints`
  onto a fresh install may need to run `ak apply_blueprint` manually
  once. Not silently worked around with a cron job or an extra
  controller.
