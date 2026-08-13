# 2. Use kind for local development

## Status

Accepted

## Context

Aegis needs a local Kubernetes environment for developing and testing
GitOps and security configuration before anything runs on persistent
infrastructure (home cluster, cloud). The realistic options were kind,
minikube, and k3d.

## Decision

Use `kind` (Kubernetes-in-Docker).

Reasons specific to this project:

- Runs entirely as Docker containers, no VM or hypervisor layer — cheap to
  create and destroy repeatedly, which matters for testing destructive
  scenarios (security-lab attacks, disaster-recovery drills) without risk
  to anything persistent.
- Config-file-driven (`bootstrap/kind/cluster.yaml`), so the cluster shape
  is declarative and versioned like everything else in this repo, rather
  than built up through imperative CLI flags.
- Multi-node topologies are a config change, not a different tool, which
  matters later when testing node-level failure or network-policy
  behavior across nodes.

## Consequences

- `kind` clusters are not a realistic stand-in for home/cloud networking,
  storage, or node characteristics — conclusions drawn from `kind` about
  those areas need to be re-verified once a persistent cluster exists.
- `kind` remains the environment for local development and disposable
  experiments even after a persistent home cluster exists; it is not
  replaced (see `CLAUDE.md`).
