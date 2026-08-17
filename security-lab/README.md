# Security lab

Deliberate attack scenarios run against the real `dev-kind` cluster, each
proving a specific control actually stops the thing it's supposed to
stop — not just that the control's YAML exists. A lab is only added once
the control it tests is already implemented (see `CLAUDE.md`); labs don't
come before the mechanism they exercise.

Each lab follows the same structure: objective, threat, vulnerable
example, expected defense, test procedure, observed result, remediation.

## Labs

- [`privileged-container/`](privileged-container/) — Kyverno
  `disallow-privileged-containers`
- [`latest-image-tag/`](latest-image-tag/) — Kyverno `disallow-latest-tag`
- [`flux-drift/`](flux-drift/) — Flux GitOps drift correction
- [`leaked-secret/`](leaked-secret/) — Gitleaks secret scanning
- [`network-lateral-movement/`](network-lateral-movement/) — NetworkPolicy
  protecting the Authentik database
- [`unsigned-image/`](unsigned-image/) — Kyverno `verifyImages` signature
  admission for aegis-api
- [`image-automation/`](image-automation/) — Flux Image Automation digest
  invariant for aegis-api

## Planned (not yet backed by a control, so not labs yet)

- `rbac-escalation/` — needs least-privilege RBAC conventions first
- `service-account-abuse/` — needs per-workload RBAC review first
