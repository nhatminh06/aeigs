# Aegis

Self-hosted Kubernetes platform managed declaratively through Git with
FluxCD. Local development uses `kind`; a persistent home cluster (K3s,
later Talos) and an optional AWS EKS environment are long-term targets.
Security controls (admission policy, encrypted secrets, image scanning and
signing, network isolation, centralized identity) are added one layer at a
time as the platform matures — see `CLAUDE.md` for the engineering rules
that govern how this repository is built.

## Status

```
Implemented:
- local kind cluster (create/delete via scripts/cluster-up.sh, cluster-down.sh)
- Flux reconciliation on dev-kind

In progress:
- (nothing currently)

Planned:
- first GitOps-managed application
- HelmRelease conventions
- SOPS + age secrets
- Prometheus / Grafana
- Kyverno admission policies
- security-lab attack scenarios
- supply-chain baseline (scanning, SBOM, signing)
- Authentik identity
- NetworkPolicy / default-deny
- persistent home cluster
- backup and disaster-recovery drills
```

## Prerequisites (for local development)

- Docker
- `kind`
- `kubectl`
- `flux` CLI

## Architecture (current stage)

```
Laptop
  |
Docker
  |
kind (cluster "aegis-dev")
  |
FluxCD (reconciling clusters/dev-kind from this repo)
```

Create the cluster with `scripts/cluster-up.sh` and remove it with
`scripts/cluster-down.sh` (destructive — deletes all workloads on it,
no confirmation prompt). Both scripts are idempotent: re-running
`cluster-up.sh` on an existing cluster or `cluster-down.sh` with no
cluster present is a no-op rather than an error.

This repository has no GitHub (or other) remote yet, so Flux's
`GitRepository` can't clone it directly. `scripts/git-bridge-up.sh` starts
a local `git http-backend` bridge (Python's CGI `http.server`, bound to
`127.0.0.1`) that serves this repo to the kind node over
`http://host.docker.internal:8099`; `scripts/git-bridge-down.sh` stops it.
This is a local-development-only workaround, not a long-term design —
once a real remote exists, `clusters/dev-kind/flux-system/gotk-sync.yaml`
should point at it and the repo should switch to `flux bootstrap`.

To bring the platform up from a stopped state: `cluster-up.sh`, then
`git-bridge-up.sh`, then apply
`clusters/dev-kind/flux-system/gotk-components.yaml` and `gotk-sync.yaml`
once (Flux self-manages after that — further changes to
`clusters/dev-kind/` just need a commit).

GitOps-managed applications and every security/observability layer
described in `CLAUDE.md` are planned but not yet present in this
repository. Nothing above this stage should be assumed to work until the
Status section says it's implemented.

## Roadmap

Aegis evolves over months, in small PR-sized increments: repository
foundation, local kind cluster, Flux bootstrap, a first GitOps-managed
application, secrets (SOPS), observability (Prometheus/Grafana), admission
control (Kyverno), a security lab of deliberate attack scenarios, a
software supply-chain baseline, identity (Authentik), network policy, and
eventually a persistent home cluster with backup/disaster-recovery drills.
Each phase is implemented, validated, and documented before the next
begins.
