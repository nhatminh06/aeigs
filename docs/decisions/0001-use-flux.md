# 1. Use FluxCD as the GitOps reconciler

## Status

Accepted

## Context

Aegis needs a controller that continuously reconciles cluster state from
Git, rather than a one-shot `kubectl apply` pipeline. The two mainstream
options are FluxCD and Argo CD.

## Decision

Use FluxCD.

Reasons specific to this project:

- Flux is a set of Kubernetes controllers (source, kustomize, helm,
  notification) rather than a separate web UI/API server — it fits the
  "understand and maintain a small set of tools" principle better than
  operating a second application alongside the cluster.
- Native `Kustomization` and `HelmRelease` CRDs cover the plain-Kustomize
  and later-Helm workflow this repo already uses, without an extra
  abstraction layer (Argo CD's "Application" CRD would add one).
- `flux bootstrap github` handles the deploy-key and sync-manifest setup
  in one command and is idempotent, which matters for a project that
  expects to bootstrap the same pattern across multiple clusters
  (dev-kind, home, eventually cloud).

## Consequences

- No Argo CD web UI; cluster state is inspected via `flux get` / `kubectl`
  instead.
- Multi-cluster and multi-tenant patterns will need to be built explicitly
  later (Flux doesn't provide Argo CD's App-of-Apps UI), following the
  directory-per-cluster convention already in `CLAUDE.md`.
