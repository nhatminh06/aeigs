# Runbook: home-k3s observability

Applies to Prometheus/Grafana on `home-k3s`
(`observability/kube-prometheus-stack/home-k3s/`). Not a general SRE
manual — only what differs from ordinary kube-prometheus-stack
operation, and how to tell apart the failure modes that look similar
from the outside.

## Health checks, in order

1. **Pods**: `kubectl -n observability get pods` — Prometheus,
   Grafana, kube-state-metrics, node-exporter, the operator, all
   `Running`. A Prometheus pod cycling through a few restarts in the
   minutes right after a host reboot is expected (WAL replay/
   compaction competing for disk I/O with everything else coming back
   up at once) — give it a few minutes before treating it as a real
   failure; check `kubectl -n observability logs
   prometheus-kube-prometheus-stack-prometheus-0 -c prometheus` for
   `WAL checkpoint complete` / `Server is ready to receive web
   requests` to confirm it settled.
2. **Target discovery**: port-forward
   (`kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus
   9090:9090`) and check `/api/v1/targets` for `job=aegis-api`,
   `health: up`.
3. **Rules loaded**: `/api/v1/rules` — `aegis-api.rules` (recording)
   and `aegis-api.alerts` (alerting) groups present, alerts `health:
   ok`, `state: inactive` under normal traffic.
4. **Grafana**: `https://grafana.aegis.home.arpa/api/health` → JSON
   `{"database":"ok",...}`. Dashboard: `/api/search` (with basic auth)
   should list `aegis-api (home-k3s)`.

## Differentiating failure modes

These look similar from a browser but have different causes:

- **Ingress broken** (nginx down, cert expired/not reloaded, wrong
  route): `curl` to `https://api.../healthz` itself fails or returns
  the wrong thing. Prometheus's own scrape of `/metrics` is
  **unaffected** — it goes straight to the Service, never through the
  ingress. See `docs/runbooks/home-k3s-ingress-recovery.md`.
- **NetworkPolicy denying Prometheus**: ingress path to aegis-api still
  works, but the Prometheus target shows `health: down` with a
  connection-refused/timeout error, and `kubectl -n aegis-api get
  networkpolicy aegis-api-ingress -o yaml` doesn't list
  `observability`'s Prometheus pod label as an allowed source.
- **Application broken**: both the ingress path and the direct
  `/metrics` scrape fail identically, and `kubectl -n aegis-api get
  pods` shows the Pod itself unhealthy.
- **Prometheus scrape broken but everything else fine**: ingress works,
  app is healthy, target shows `health: down` with a Prometheus-side
  error (e.g. `context deadline exceeded`) — check the ServiceMonitor's
  `path`/`port` still match the Service
  (`apps/aegis-api/home-k3s/servicemonitor.yaml`) and that the `release:
  kube-prometheus-stack` label wasn't dropped (the chart's default
  `serviceMonitorSelector` matches only on that label).

## Storage and retention

Prometheus: `local-path` PVC, `2Gi`, `24h` retention — a deliberate
choice for this persistent host (see
`docs/decisions/0015-home-k3s-nginx-ingress.md`'s reasoning and
`observability/kube-prometheus-stack/home-k3s/helmrelease.yaml`'s
comments), not copied from dev-kind's disposable-cluster `6h`. Survives
a host reboot — verified live. Grafana has no PVC: dashboards/config
are Git-provisioned (the `grafana_dashboard: "1"`-labeled ConfigMap
pattern), and there's no other mutable Grafana state worth persisting.

## What NOT to do

- Don't chase every Kubernetes control-plane scrape target to green —
  `kubeControllerManager`/`kubeScheduler`/`kubeEtcd`/`kubeProxy` are
  deliberately disabled in the Helm values; a single-node K3s control
  plane doesn't expose them the way a kubeadm cluster's own dashboards
  assume.
- Don't add Alertmanager or any notification path "while you're in
  here" — Prometheus's own rule evaluation (inactive/active in the API)
  is the whole point of this milestone's SLO proof; no paging
  infrastructure was in scope.
- Don't fake an Authentik/OIDC config for Grafana — local admin auth is
  the deliberate, documented state until a future Authentik-on-home-k3s
  milestone.
