# 5. Use Kyverno for admission policy

## Status

Accepted

## Context

Aegis needs to reject workloads that violate baseline security
expectations (privileged containers, mutable `latest` tags, and more
later) at admission time, not just by convention. The realistic options
were Kyverno and OPA/Gatekeeper (Rego-based).

## Decision

Use Kyverno. Policies are plain Kubernetes YAML (`ClusterPolicy`), which
fits `CLAUDE.md`'s "automation must be understandable by a human operator"
rule better than learning Rego for a project that otherwise avoids
unnecessary new languages/DSLs. Kyverno itself is installed via Helm
(`security/kyverno/helmrelease.yaml`, pinned `3.8.2`) for the same reason
kube-prometheus-stack is — a CRD-heavy upstream controller, not something
worth hand-maintaining as plain manifests.

Policies are applied by a separate Flux `Kustomization`
(`kyverno-policies`) that `dependsOn` the `kyverno` Kustomization, since
`ClusterPolicy` is a CRD Kyverno itself installs — policies can't apply
before the controller exists.

Each policy starts in `validationFailureAction: Enforce` (actually blocks,
not just reports) — introduced with a passing and a failing test proving
real admission behavior, per `CLAUDE.md`'s "tested security controls over
a security-tool collection."

## Consequences

- Only two policies exist so far: no privileged containers, no `latest`
  image tags (see `security/policies/`). More are added one at a time,
  each with its own tests, not as a bulk policy-pack import.
- `Enforce` mode means a misconfigured policy can block legitimate
  deployments, including Flux's own reconciliation of workloads. This is
  accepted deliberately (see philosophy: tested controls over convenience)
  but means new policies should be tested against `apps/demo-app` and the
  observability stack before being trusted.
- Kyverno's background scanning, cleanup controller, and reports
  controller are left at chart defaults (not tuned or disabled) — revisit
  if resource usage or noise becomes a real problem on `kind`.
