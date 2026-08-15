# Lab: privileged container

## Objective

Confirm that a pod requesting a privileged container is actually rejected
at admission time, not just discouraged by convention.

## Threat

A privileged container (`securityContext.privileged: true`) has
essentially the same access to the host as root outside a container:
device access, kernel capabilities, and the ability to affect other
containers on the node. A single compromised or misconfigured workload
requesting this is a direct path to full node compromise.

## Vulnerable example

[`security/policies/tests/invalid-privileged.yaml`](../../security/policies/tests/invalid-privileged.yaml)
— a plain `Pod` with `securityContext.privileged: true`.

## Expected defense

The Kyverno `ClusterPolicy`
[`disallow-privileged-containers`](../../security/policies/disallow-privileged-containers.yaml)
(`validationFailureAction: Enforce`) should reject the pod at admission,
before it's ever scheduled.

## Test procedure

```
kubectl apply -f security/policies/tests/invalid-privileged.yaml
```

## Observed result

Run against `dev-kind` on 2026-08-13T18:47:37Z:

```
Error from server: error when creating "invalid-privileged.yaml": admission webhook
"validate.kyverno.svc-fail" denied the request:

resource Pod/default/test-privileged was blocked due to the following policies

disallow-privileged-containers:
  privileged-containers: 'validation error: Privileged containers are not allowed.
    Set securityContext.privileged to false (or omit it) on every container. rule
    privileged-containers failed at path /spec/containers/0/securityContext/privileged/'
```

Rejected before creation — no pod, no container, no node access. The
matching valid case
([`security/policies/tests/valid-privileged.yaml`](../../security/policies/tests/valid-privileged.yaml),
`privileged: false`) was created successfully in the same test run (see
`security/policies/tests/README.md`).

## Remediation / what stops this

Already in place: Kyverno admission enforcement, `Enforce` mode (not
`Audit`), applied to every namespace except `kube-system`/
`kube-node-lease`/`kube-public` (see the `exclude` block — `kube-proxy`
legitimately runs privileged there).

**Also covers ephemeral containers (`kubectl debug`)**: this policy's
pattern has checked `ephemeralContainers`/`initContainers` since the
policy was first added, and `match.kinds: [Pod]` alone is enough for
Kyverno to see an ephemeral-container admission request — Kubernetes
doesn't change a resource's `kind` for a subresource request, only adds a
`subresource` field. Verified live on 2026-08-15: a privileged ephemeral
container attached via `kubectl debug --custom` was blocked with no
policy change needed. (An earlier assumption in this repository that an
explicit `Pod/ephemeralcontainers` match plus `background: false` was
required to close a bypass here came from a flawed live reproduction and
did not hold up on retest — see
`docs/decisions/0008-kyverno-image-tag-parsed-matching.md`.)

Not yet covered: nothing yet enforces `allowPrivilegeEscalation: false`
or a restricted `seccompProfile`/capabilities baseline across the board
(only `apps/demo-app` sets those manually) — a real pod-security-standards
policy set is future work, not assumed to exist yet.
