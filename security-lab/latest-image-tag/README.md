# Lab: mutable / missing image tag

## Objective

Confirm that both an explicit `:latest` tag and an implicit one (no tag
at all) are rejected at admission, not just the literal string `:latest`.

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

## Expected defense

The Kyverno `ClusterPolicy`
[`disallow-latest-tag`](../../security/policies/disallow-latest-tag.yaml)
has two rules: `require-image-tag` (rejects a missing tag) and
`disallow-latest-tag` (rejects the literal `:latest`). Both in `Enforce`
mode.

## Test procedure

```
kubectl apply -f security/policies/tests/invalid-latest.yaml
kubectl apply -f security/policies/tests/invalid-latest-notag.yaml
```

## Observed result

Run against `dev-kind` on 2026-08-13T18:47:37Z, both rejected:

```
resource Pod/default/test-latest-tag was blocked due to the following policies
disallow-latest-tag:
  disallow-latest-tag: 'validation error: Using the ''latest'' image tag is not
    allowed; pin to a specific version. ...'

resource Pod/default/test-no-tag was blocked due to the following policies
disallow-latest-tag:
  require-image-tag: 'validation error: An image tag is required (an untagged
    image defaults to :latest). ...'
```

The no-tag case specifically confirms the policy doesn't just pattern-match
the string `latest` — it actually understood the implicit default. The
matching valid case
([`security/policies/tests/valid-latest.yaml`](../../security/policies/tests/valid-latest.yaml),
`nginx:1.27.3`) was created successfully in the same test run.

## Remediation / what stops this

Already in place: both rules enforced cluster-wide. Every image currently
running on this cluster (`podinfo:6.14.1`, the `kube-prometheus-stack`
chart's images, Kyverno's own images) already uses pinned tags, so
enabling this didn't require changing anything else.

Not yet covered: a pinned tag can still be re-pushed to the same tag at
the registry (tags aren't immutable by default on most registries).
Pinning to a digest (`image@sha256:...`) instead of a tag would close
that gap — deferred to the supply-chain phase (signing/SBOM), where
digest pinning fits naturally alongside Cosign verification.
