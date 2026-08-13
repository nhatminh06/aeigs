# 4. Use Helm (via HelmRelease) for kube-prometheus-stack

## Status

Accepted

## Context

`CLAUDE.md` defaults to plain Kustomize and treats Helm as something to
introduce only once an application genuinely needs its templating —
avoiding a wrapper around every third-party chart "just in case."

`kube-prometheus-stack` (Prometheus + Grafana + kube-state-metrics +
node-exporter + the Prometheus Operator and its CRDs) is the first case
that meets that bar: it's a single upstream chart install driving several
CRD-based Kubernetes controllers (`Prometheus`, `Alertmanager`,
`ServiceMonitor`, etc.), version-gated, with thousands of lines of
interdependent default values. Hand-writing and maintaining equivalent
plain manifests would mean re-implementing the operator pattern the chart
already provides, with no benefit.

## Decision

Deploy `kube-prometheus-stack` via a Flux `HelmRelease`
(`observability/kube-prometheus-stack/helmrelease.yaml`), pointed at a
pinned chart version through a `HelmRepository`. `HelmRelease` values are
kept inline in the manifest rather than a separate `values.yaml`, since
the overrides here are small (disabling `alertmanager`, pointing Grafana
at an existing Secret, trimming retention) — a separate file would be
one more layer for three keys.

## Consequences

- Chart version is pinned (`88.3.0`); bumping it is a deliberate, reviewed
  change to the manifest, not a silent drift.
- Grafana's admin credentials come from a SOPS-encrypted `Secret`
  (`grafana-admin`, referenced via `grafana.admin.existingSecret`), not a
  value in the chart's `values` block — consistent with the no-plaintext
  rule established in
  `docs/decisions/0003-use-sops-age-for-secrets.md`.
- This does not make Helm the default going forward. `apps/demo-app`
  stays plain Kustomize; each future chart is still evaluated on whether
  it genuinely needs Helm, not adopted as a default policy.
- Alertmanager, persistent storage, and Grafana dashboard provisioning
  beyond the chart's defaults are explicitly out of scope for this change
  and deferred to when alerting is actually needed.
