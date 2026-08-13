# Policy tests

Manual admission tests for each `ClusterPolicy` in `security/policies/`.
These aren't applied by Flux (they're deliberately invalid in half the
cases) — apply them by hand against a cluster with Kyverno running to
verify a policy's actual admission behavior, not just that its YAML
parses.

## disallow-privileged-containers

```
kubectl apply -f valid-privileged.yaml     # expected: created
kubectl apply -f invalid-privileged.yaml   # expected: rejected by admission webhook
```

Observed on `dev-kind`, 2026-08-13: `invalid-privileged.yaml` was
rejected with `disallow-privileged-containers` in the error;
`valid-privileged.yaml` was created successfully. Cleaned up after.

## disallow-latest-tag

```
kubectl apply -f valid-latest.yaml           # expected: created (pinned tag)
kubectl apply -f invalid-latest.yaml         # expected: rejected (image:latest)
kubectl apply -f invalid-latest-notag.yaml   # expected: rejected (no tag at all)
```

Observed on `dev-kind`, 2026-08-13: both invalid cases were rejected
(`disallow-latest-tag` and `require-image-tag` respectively);
`valid-latest.yaml` was created successfully. Cleaned up after.

Existing platform workloads (`apps/demo-app`, `kube-prometheus-stack`,
Kyverno itself) all continued reconciling normally after both policies
went active — none of them use privileged containers or unpinned tags.
