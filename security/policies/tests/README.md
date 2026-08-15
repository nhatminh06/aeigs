# Policy tests

Two layers of testing exist here, and neither alone is sufficient — this
directory's own history is the evidence, not a hypothetical.

- **`kyverno test .`** — static, repeatable, CI-enforced. Runs the rule
  engine directly against the fixtures in this directory as a single
  CREATE-shaped evaluation. Fast, but it doesn't model which Kubernetes
  *operation* (CREATE/UPDATE/DELETE) a request is, or Kyverno's old-vs-new
  object comparison for deny-condition rules.
- **Manual `kubectl apply`/`kubectl debug`** — live, against a real
  cluster with Kyverno actually running. Slower, but it's the only way to
  prove the admission webhook behaves correctly across those operations
  and comparisons, which `kyverno test` can't simulate.

These fixtures aren't applied by Flux (they're deliberately invalid in
half the cases).

## Why both layers matter (not hypothetical)

Two real gaps were only found by testing live, never by `kyverno test`:

1. **`disallow-latest-tag` didn't look at `initContainers`/
   `ephemeralContainers` at all.** Its pattern only checked
   `spec.containers[*].image`, so a `:latest` init or ephemeral container
   passed silently — `kyverno test` reported this "passing" too, because
   nothing in the pattern ever asked about those fields, and a fixture
   that isn't checked can't fail.
2. **Rewriting the rule to use Kyverno's parsed `images` context (to fix
   the registry-port-vs-tag ambiguity below) introduced two live-only
   bugs that no static fixture could have caught:** `deny`-condition
   rules default `allowExistingViolations: true`, which skips enforcement
   on UPDATE whenever Kyverno's old-vs-new comparison decides the
   resource was "already" non-compliant — in testing, this let a
   `:latest` ephemeral debug container through even on a pod whose real
   containers were all correctly pinned. Separately, the same rule with
   no `operations` scoping evaluated on DELETE too, where the parsed
   `images` context isn't populated the same way — this didn't just fail
   to validate, it **errored and blocked deletion of every pod in the
   cluster** until scoped to `operations: [CREATE, UPDATE]`. Both were
   found by actually deleting a pod against the candidate policy, not by
   `kyverno test`, which never exercises anything but the single-object
   evaluation.

By contrast, `disallow-privileged-containers`'s pattern already checked
`ephemeralContainers`/`initContainers` from the very first commit that
added it, and match.kinds: `["Pod"]` — no explicit
`Pod/ephemeralcontainers` subresource kind — was already sufficient to
catch a privileged `kubectl debug` container live on `dev-kind`, verified
2026-08-15. Kubernetes doesn't change a resource's `kind` for a
subresource admission request (only adds a `subresource` field), so a
plain `Pod` match already receives ephemeral-container requests here; an
earlier assumption in this repository's history that explicit
`Pod/ephemeralcontainers` matching plus `background: false` was required
to close a bypass was based on a flawed live reproduction and did not
hold up on retest. No change was needed to that policy.

## disallow-privileged-containers

```
kubectl apply -f valid-privileged.yaml     # expected: created
kubectl apply -f invalid-privileged.yaml   # expected: rejected by admission webhook
```

Observed on `dev-kind`, 2026-08-13: `invalid-privileged.yaml` was
rejected with `disallow-privileged-containers` in the error;
`valid-privileged.yaml` was created successfully. Cleaned up after.

initContainer and ephemeralContainer variants
(`*-privileged-initcontainer.yaml`, `*-privileged-ephemeralcontainer.yaml`)
are covered by `kyverno test .`. The ephemeralContainer case was also
verified live via `kubectl debug --custom` on 2026-08-15 (see above) —
confirmed blocked without any policy change.

## disallow-latest-tag

```
kubectl run t1 --image=nginx:1.27 --dry-run=server ...                        # expected: created (pinned tag)
kubectl run t2 --image=nginx:latest --dry-run=server ...                      # expected: rejected (:latest)
kubectl run t3 --image=nginx --dry-run=server ...                             # expected: rejected (no tag)
kubectl run t4 --image=registry.example.com:5000/app --dry-run=server ...     # expected: rejected (port, not a tag)
kubectl run t5 --image=registry.example.com:5000/app:1.2.3 --dry-run=server . # expected: created (port + real tag)
```

Observed on `dev-kind`, 2026-08-15: all five behaved as expected via
`kubectl ... --dry-run=server`. A real (non-dry-run) pod was then created
and a `kubectl debug` ephemeral container attached: a `:latest` ephemeral
container was rejected, a pinned one was accepted, and the pod was
deleted afterward without issue — confirming the `operations` scoping fix
above didn't just prevent the delete-blocking bug in testing, it holds
against the real webhook too.

initContainer and ephemeralContainer variants
(`*-latest-initcontainer.yaml`, `*-latest-ephemeralcontainer.yaml`), the
registry-port cases (`*-latest-port.yaml`), and the digest-pinned case
(`valid-latest-digest.yaml`) are covered by `kyverno test .`.

Existing platform workloads (`apps/demo-app`, `kube-prometheus-stack`,
Kyverno itself, Authentik) all continued reconciling normally after this
change — none of them use privileged containers, unpinned tags, or
registry ports.
