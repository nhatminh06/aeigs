#!/usr/bin/env bash
# Proves Kyverno's verify-aegis-api-image policy actually gates admission
# on a real Cosign signature, not merely on the policy object existing.
#
# All four candidates are applied with --dry-run=server, so nothing here
# is ever actually scheduled. Each candidate uses an immutable digest, not
# a mutable tag.
#
# Exits 0 only if every case matches its expected admission outcome.
set -euo pipefail

EXPECTED_CONTEXT="kind-aegis-dev"
NS="aegis-api"

# The currently Git-owned digest — signed by this project's own release
# workflow with an identity Kyverno's policy trusts.
SIGNED_DIGEST="sha256:7e025135b6bbcfd8f895808472539674966a46f8c044424b6664e57297845b0f"
# v0.1.0's digest: published before this milestone, confirmed unsigned
# with `cosign verify` before being used here.
UNSIGNED_DIGEST="sha256:63571b7666b670a56e622f446c0a704f47f724c0ad53ea4f137537b948002c00"
# v0.1.2's own linux/amd64 platform manifest. Cosign signed the multi-
# platform index digest above, not this child digest directly, so it
# proves the signature binds to the exact digest referenced — not to
# "the release" loosely, and not to any digest that happens to be part of
# the same published artifact.
CHILD_DIGEST="sha256:239a0065e1694b98ed4c8b96964ffd26057da412c5b0cda1d15003f19a1ec4ce"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "error: required command 'kubectl' not found on PATH" >&2
  exit 1
fi

current_context="$(kubectl config current-context 2>/dev/null || true)"
if [ "${current_context}" != "${EXPECTED_CONTEXT}" ]; then
  echo "error: kubectl context is '${current_context}', expected '${EXPECTED_CONTEXT}'" >&2
  exit 1
fi

candidate() {
  local name="$1" digest="$2"
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: ${NS}
  labels:
    app: aegis-api
spec:
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: aegis-api
      image: ghcr.io/nhatminh06/aegis-api@${digest}
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
EOF
}

failed=0

echo "==> signed release digest (v0.1.2 index) — expect ALLOWED"
if candidate lab-signed "${SIGNED_DIGEST}" | kubectl apply --dry-run=server -f - >/dev/null 2>&1; then
  echo "PASS: signed digest admitted"
else
  echo "FAIL: signed digest was denied — the trusted release image should be admissible" >&2
  failed=1
fi

echo "==> unsigned digest (v0.1.0) — expect DENIED"
if candidate lab-unsigned "${UNSIGNED_DIGEST}" | kubectl apply --dry-run=server -f - >/dev/null 2>&1; then
  echo "FAIL: unsigned digest was admitted — verify-aegis-api-image is not enforcing" >&2
  failed=1
else
  echo "PASS: unsigned digest denied"
fi

echo "==> unsigned platform-child digest of the signed release — expect DENIED"
if candidate lab-child-digest "${CHILD_DIGEST}" | kubectl apply --dry-run=server -f - >/dev/null 2>&1; then
  echo "FAIL: platform-child digest was admitted — the release signature is authorizing a digest it never signed" >&2
  failed=1
else
  echo "PASS: platform-child digest denied"
fi

exit "${failed}"
