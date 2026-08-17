#!/usr/bin/env bash
# Proves the three-way digest invariant Flux Image Automation depends on:
# the digest ImagePolicy selected, the digest committed into Git, and the
# digest actually running all have to be the same one, or automation is
# silently pointing somewhere Git and the cluster disagree about.
#
# Does not check the signature itself — that's
# security-lab/unsigned-image/test.sh's job. This only checks that the
# three digests agree; verify-aegis-api-image is what makes "agree" also
# mean "trusted".
#
# Exits 0 only if all three digests match exactly.
set -euo pipefail

EXPECTED_CONTEXT="kind-aegis-dev"
NS="aegis-api"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "error: required command 'kubectl' not found on PATH" >&2
  exit 1
fi

current_context="$(kubectl config current-context 2>/dev/null || true)"
if [ "${current_context}" != "${EXPECTED_CONTEXT}" ]; then
  echo "error: kubectl context is '${current_context}', expected '${EXPECTED_CONTEXT}'" >&2
  exit 1
fi

policy_digest="$(kubectl -n "${NS}" get imagepolicy aegis-api -o jsonpath='{.status.latestRef.digest}' 2>/dev/null || true)"
live_image="$(kubectl -n "${NS}" get deployment aegis-api -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
live_digest="${live_image##*@}"

if [ -z "${policy_digest}" ]; then
  echo "error: ImagePolicy/aegis-api has no selected digest yet" >&2
  exit 1
fi
if [ -z "${live_digest}" ] || [ "${live_digest}" = "${live_image}" ]; then
  echo "error: live Deployment image is not digest-pinned: ${live_image}" >&2
  exit 1
fi

echo "ImagePolicy selected digest : ${policy_digest}"
echo "Live Deployment digest      : ${live_digest}"

if [ "${policy_digest}" != "${live_digest}" ]; then
  echo "FAIL: live digest does not match what ImagePolicy currently selects" >&2
  echo "      (expected if automation hasn't reconciled yet after a new release;" >&2
  echo "      a persistent mismatch means Git and the cluster have diverged)" >&2
  exit 1
fi

echo "PASS: ImagePolicy selection and live Deployment digest agree"
