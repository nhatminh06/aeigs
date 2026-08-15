# Lab: mutable / missing image tag

## Objective

Confirm that an explicit `:latest` tag, an implicit one (no tag at all),
and a tag-shaped-but-not-actually-a-tag registry port are all rejected at
admission — not just the literal string `:latest`.

## Threat

A mutable tag means the image behind a running reference can change
without a corresponding Git change — breaking reproducibility (the
manifest no longer describes what's actually running) and giving an
attacker with registry push access a way to swap a workload's image
without touching Kubernetes or Git at all.

## Vulnerable examples

- [`security/policies/tests/invalid-latest.yaml`](../../security/policies/tests/invalid-latest.yaml)
  — `image: nginx:latest`
- [`security/policies/tests/invalid-latest-notag.yaml`](../../security/policies/tests/invalid-latest-notag.yaml)
  — `image: nginx` (no tag; Kubernetes defaults this to `:latest`
  implicitly, which is easy to miss when reviewing a diff)
- [`security/policies/tests/invalid-latest-port.yaml`](../../security/policies/tests/invalid-latest-port.yaml)
  — `image: registry.example.com:5000/app` (no tag either — the colon
  here is a registry port, not a tag separator; a control that matches
  the raw string for "contains a colon" would wrongly treat this as
  pinned)

## Expected defense

The Kyverno `ClusterPolicy`
[`disallow-latest-tag`](../../security/policies/disallow-latest-tag.yaml),
rule `require-pinned-image`, in `Enforce` mode. It checks Kyverno's parsed
`images` context (registry/name/tag/digest already split apart) rather
than matching the raw image string, so it isn't fooled by a registry
port and correctly treats a digest-pinned image (no tag, but immutable)
as pinned.

## Test procedure

```
kubectl run t1 --image=nginx:1.27 --dry-run=server -o name
kubectl run t2 --image=nginx:latest --dry-run=server -o name
kubectl run t3 --image=nginx --dry-run=server -o name
kubectl run t4 --image=registry.example.com:5000/app --dry-run=server -o name
kubectl run t5 --image=registry.example.com:5000/app:1.2.3 --dry-run=server -o name
```

## Observed result

Run against `dev-kind` on 2026-08-15: `t1` and `t5` created; `t2`, `t3`,
`t4` rejected, e.g.:

```
resource Pod/default/t2 was blocked due to the following policies
disallow-latest-tag:
  require-pinned-image: Container images must be pinned to a specific tag
    or digest. ...
```

A real (non-dry-run) pod was then created and a `kubectl debug` ephemeral
container attached: a `:latest` ephemeral container was rejected, a
pinned one was accepted, and the pod was deleted afterward without
issue — see
`docs/decisions/0008-kyverno-image-tag-parsed-matching.md` for two
live-only bugs found and fixed in the course of building this (an
ephemeral-container bypass caused by a Kyverno default, and a bug that
briefly blocked deletion of every pod in the cluster).

## Remediation / what stops this

Already in place: enforced cluster-wide (except
`kube-system`/`kube-node-lease`/`kube-public`), covering `containers`,
`initContainers`, and `ephemeralContainers`, and correctly distinguishing
a registry port from an image tag. Every image currently running on this
cluster (`podinfo:6.14.1`, the `kube-prometheus-stack` chart's images,
Kyverno's own images, Authentik's) already uses pinned tags, so enabling
this didn't require changing anything else.

Not yet covered: a pinned *tag* can still be re-pushed to the same tag at
the registry (tags aren't immutable by default on most registries) — this
policy now recognizes a digest reference as pinned, but nothing in this
repository verifies that the digest actually matches a trusted, signed
build yet. That's the supply-chain phase (signing/SBOM via Cosign),
deferred.
