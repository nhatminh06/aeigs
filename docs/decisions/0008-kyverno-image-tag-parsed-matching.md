# 8. Match parsed image fields instead of the raw image string

## Status

Accepted

## Context

`disallow-latest-tag.yaml` only checked `spec.containers[*].image`, using
raw-string patterns (`image: "*:*"` to require a tag, `image: "!*:latest"`
to reject `:latest`). This had two problems, discovered while extending
its coverage to match `disallow-privileged-containers.yaml`'s existing
`initContainers`/`ephemeralContainers` handling:

1. **No `initContainers`/`ephemeralContainers` coverage at all** — the
   pattern never referenced those fields, so a `:latest` init or ephemeral
   container passed silently. `kyverno test` reported this as passing
   too, since a fixture that isn't checked can't fail; only a live
   `kubectl debug` reproduction (and manually adding a matching init
   container) surfaced it.
2. **Raw-string matching can't distinguish an image tag from a registry
   port.** `registry.example.com:5000/app` has no tag, but `"*:*"`
   matches it anyway — the colon before `5000` looks identical to a tag
   separator to a glob pattern.

While retesting the ephemeral-container path, a **separate, pre-existing
assumption in this repository turned out to be wrong**:
`disallow-privileged-containers.yaml` has checked
`ephemeralContainers`/`initContainers` since it was first added, using
`match.kinds: [Pod]` with no explicit ephemeral-container subresource
entry, and a live `kubectl debug --custom` test on 2026-08-15 confirmed
it already blocks a privileged ephemeral container with no changes.
Kubernetes doesn't change a resource's `kind` for a subresource admission
request — it only adds a `subresource` field — so a plain `Pod` match
already receives these requests here. An earlier note in this repository
claiming `Pod/ephemeralcontainers` + `background: false` were required to
close a bypass was based on a flawed live reproduction (a malformed
`kubectl debug --custom` payload) and did not hold up on retest. No
change was made to `disallow-privileged-containers.yaml`.

## Decision

Rewrite `disallow-latest-tag` as a single rule using Kyverno's
automatically-parsed `images` context (`registry`/`name`/`tag`/`digest`
per container, already split apart) instead of matching the raw image
string, covering `containers`, `initContainers`, and
`ephemeralContainers`. A container fails if its tag is `latest`, or if it
has neither a tag nor a digest (digest-pinned images are treated as
pinned, since a digest is immutable even without a tag).

Building this surfaced two more live-only bugs, both fixed in the same
change:

- **`allowExistingViolations` defaults to `true`** for rules using `deny`
  conditions (unlike `pattern` rules, which don't have this default).
  This skips enforcement on UPDATE whenever Kyverno's old-vs-new
  comparison decides the resource was "already" non-compliant — in
  testing, this let a `:latest` ephemeral debug container through on a
  pod whose real containers were all correctly pinned. Set explicitly to
  `false`.
- **The rule originally matched all operations**, including DELETE,
  where the parsed `images` context isn't populated the same way
  (`request.object` is empty). This didn't just fail to validate — it
  **errored and blocked deletion of every pod in the cluster** until the
  rule's `match` was scoped to `operations: [CREATE, UPDATE]`.

## Consequences

- `disallow-latest-tag` now correctly distinguishes a registry port from
  a tag, and correctly allows digest-pinned images, matching how the
  image will actually resolve at pull time.
- `kyverno test` cannot reproduce the `allowExistingViolations` or
  DELETE-operation bugs above — it evaluates each fixture as a single,
  operation-less object, not as a sequence of CREATE/UPDATE/DELETE
  requests being compared against prior state. Both were found only by
  testing the real webhook live, including actually deleting a pod
  against the candidate policy. `security/policies/tests/README.md`
  documents this so the same class of bug (trusting static results alone
  for behavior that depends on *which operation* a request is) isn't
  repeated for a future deny-condition-based policy.
- No change was needed for `disallow-privileged-containers.yaml` — this
  ADR corrects an earlier, disproven claim about it needing explicit
  ephemeral-container subresource matching.
