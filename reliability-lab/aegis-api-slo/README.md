# Lab: SLO + signed bad release + GitOps recovery

## Objective

Aegis's supply chain already proves "was this artifact produced by the
trusted pipeline?" (Cosign keyless signing, Kyverno `verifyImages`, Flux
Image Automation only ever selecting a signed digest). It does not prove
"is this artifact actually good?" — a correctly signed release can still
be a functional regression. This lab proves that gap is closed by
Prometheus, not by anything in the trust chain, and that recovery goes
back through Git, not a live `kubectl` patch.

## Question

If a correctly signed application regression is automatically released,
how quickly and clearly can Aegis determine: something is wrong, what is
wrong, which release introduced it, whether Kubernetes itself considers
the workload healthy, and how to recover through Git?

## Metrics used

Read directly from `~/aegis-api/internal/api/api.go`, not assumed:

- `aegis_api_http_requests_total{method,path,status}` — CounterVec
- `aegis_api_http_request_duration_seconds{method,path}` — Histogram,
  Prometheus `DefBuckets` (0.005s .. 10s)
- `aegis_api_work_requests_total` — Counter

`/healthz`, `/readyz`, and `/metrics` are instrumented by the same
middleware and appear under their own `path` label in the first two
series above. Every SLI query below is scoped to `path=~"/api/v1/.*"` so
health-probe and scrape traffic never dilutes the user-facing ratio.

## Lab SLIs and objectives

**These are Aegis development service objectives — learning/operational
thresholds sized for a single-replica dev-kind lab, not a production
SLA.** They were chosen after measuring the healthy baseline below, not
before.

| SLI | Definition | Objective | Why |
|---|---|---|---|
| Availability | non-5xx responses / total responses | > 99% | baseline measured 100% |
| Error rate | 5xx responses / total responses | < 1% | baseline measured 0% |
| Latency | p95 request duration | < 100ms | baseline measured ~4.75ms; the planned regression (`value=40` recursive Fibonacci) benchmarks at ~220ms locally — comfortably separates healthy from regressed without being so tight that baseline noise trips it |

Implemented as Prometheus recording + alert rules in
`apps/aegis-api/prometheusrule.yaml`:

```
aegis_api:request_success_ratio:5m
aegis_api:http_5xx_ratio:5m
aegis_api:http_request_duration_p95_seconds:5m

AegisApiLowSuccessRatio   (aegis_api:request_success_ratio:5m < 0.99, for: 2m)
AegisApiHighErrorRate     (aegis_api:http_5xx_ratio:5m > 0.01, for: 2m)
AegisApiHighLatency       (aegis_api:http_request_duration_p95_seconds:5m > 0.1, for: 2m)
```

Discovery confirmed live via Prometheus's own `/api/v1/rules` (not just
`kubectl get prometheusrule`): both groups load, all three alert rules
`health=ok state=inactive` on the healthy baseline.

## Load pattern

`load.sh` in this directory: a fixed-rate, bounded, repeatable request
mix against `/api/v1/info` and `/api/v1/work`, run identically before and
after the regression so results are comparable.

```
BASE_URL=https://api.aegis.test RATE_HZ=10 DURATION_SEC=180 WORK_VALUE=<N> ./load.sh
```

Not a stress test — dev-kind is a single node.

## Healthy baseline (v0.1.3)

Run 2026-08-17, 13:25:39Z–13:28:39Z UTC, target rate 10 req/s for 180s,
`WORK_VALUE=10`. Actual issued: 1563 requests (curl-fork overhead brings
real throughput to ~8.7 req/s, not a Prometheus artifact).

Release identity: `version=v0.1.3`, `commit=c7280400d822bb1654a238df27581ea0d289170e`,
digest `sha256:b0845756fb57e3e37083da69b181df5dd89eca804c48dcd016e3c1a8df54ab4c`.

Measured via direct Prometheus queries (not the load generator's own
counts), `path=~"/api/v1/.*"` over the run window:

```
total requests : ~1743.6 (increase over a 210s window covering the run)
success ratio  : 100%
5xx ratio      : 0%
p50 latency    : 2.5ms
p95 latency    : 4.75ms
p99 latency    : 4.95ms
restarts       : 0
readiness      : True throughout
```

## Regression, detection, rollback, recovery

Full incident timeline, detection/recovery timing, and the emergency
procedure are in
[`docs/runbooks/aegis-api-bad-release.md`](../../docs/runbooks/aegis-api-bad-release.md).

Summary: `v0.1.4` (recursive, O(2^n) `fibonacci`) passed every
supply-chain gate and was auto-deployed by Flux Image Automation.
`WORK_VALUE=34` load (same rate/duration/paths as the baseline above)
measured p95=237ms / p99=425ms against a 100ms objective, while
availability stayed 100% and 5xx stayed 0% — Kubernetes, Kyverno, and
Hubble all reported healthy throughout. Recovered via a single Git commit
suspending `ImageUpdateAutomation` and rolling `deployment.yaml` back to
the known-good `v0.1.3` digest; no `kubectl` mutation.

`v0.1.4`'s tag, image, and signature remain untouched as incident
evidence.

Root cause fixed as `v0.1.5`: reverted `fibonacci` to its iterative
form and added `TestFibonacciStaysLinear`, a regression guard bounding
`fibonacci(40)`'s wall-clock cost generously (100ms against an actual
cost of microseconds) so it only trips on a genuine complexity-class
regression. `v0.1.5` independently passed Trivy, SBOM, Cosign
verification, and a Kyverno dry-run before automation was resumed
through Git; `ImageUpdateAutomation` then generated its own commit
(`v0.1.3 → v0.1.5`) and the same load pattern confirmed p95 back to
~4.75ms with all three alerts `inactive`.
