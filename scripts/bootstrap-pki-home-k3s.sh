#!/usr/bin/env bash
# Restores the Aegis development CA into home-k3s so cert-manager can
# issue certificates for the permanent ingress hostnames.
#
# home-k3s and dev-kind deliberately share ONE development CA rather
# than each having its own — see
# docs/decisions/0015-home-k3s-nginx-ingress.md for why. This script
# only ever RESTORES the existing CA from the same off-cluster material
# scripts/bootstrap-pki.sh (dev-kind) uses; it never generates one.
# Generating a new CA is dev-kind's script's job (--init), specifically
# so a routine home-k3s rebuild can never accidentally mint a second
# root that clients would need to separately trust.
#
# AEGIS_HOME_K3S_KUBECONFIG / AEGIS_HOME_K3S_CONTEXT exist for the same
# reason as the other *-home-k3s.sh scripts: proving reconstruction on a
# replacement host without touching the primary cluster's kubeconfig.
#
# Safe to re-run: restore is an idempotent recreate.
set -euo pipefail

EXPECTED_CONTEXT="${AEGIS_HOME_K3S_CONTEXT:-home-k3s}"
LOCAL_KUBECONFIG="${AEGIS_HOME_K3S_KUBECONFIG:-${HOME}/.kube/home-k3s.yaml}"
export KUBECONFIG="${LOCAL_KUBECONFIG}"

CA_NAMESPACE="ingress-system"
CA_SECRET="aegis-dev-ca"
PKI_DIR="${AEGIS_PKI_DIR:-${HOME}/.config/aegis/pki}"
CA_KEY="${PKI_DIR}/ca.key"
CA_CRT="${PKI_DIR}/ca.crt"

for cmd in kubectl openssl; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "error: required command '${cmd}' not found on PATH" >&2
    exit 1
  fi
done

if [ ! -f "${LOCAL_KUBECONFIG}" ]; then
  echo "error: ${LOCAL_KUBECONFIG} not found — run scripts/fetch-home-k3s-kubeconfig.sh first" >&2
  exit 1
fi

current_context="$(kubectl config current-context 2>/dev/null || true)"
if [ "${current_context}" != "${EXPECTED_CONTEXT}" ]; then
  echo "error: kubectl context is '${current_context}', expected '${EXPECTED_CONTEXT}'" >&2
  exit 1
fi

if [ ! -f "${CA_KEY}" ] || [ ! -f "${CA_CRT}" ]; then
  echo "error: no development CA found at ${PKI_DIR}" >&2
  echo "       this script only restores an existing CA — create the" >&2
  echo "       first one with scripts/bootstrap-pki.sh --init against" >&2
  echo "       dev-kind, then re-run this script" >&2
  exit 1
fi

# Same match/expiry checks as scripts/bootstrap-pki.sh — fail before
# touching the cluster rather than installing a broken pair.
key_pub="$(openssl pkey -in "${CA_KEY}" -pubout 2>/dev/null | openssl sha256 | awk '{print $NF}')"
crt_pub="$(openssl x509 -in "${CA_CRT}" -pubkey -noout 2>/dev/null | openssl sha256 | awk '{print $NF}')"
if [ -z "${key_pub}" ] || [ "${key_pub}" != "${crt_pub}" ]; then
  echo "error: ${CA_KEY} does not match ${CA_CRT}" >&2
  exit 1
fi

if ! openssl x509 -in "${CA_CRT}" -checkend 0 -noout >/dev/null 2>&1; then
  echo "error: the CA certificate at ${CA_CRT} has expired" >&2
  exit 1
fi

echo "==> CA subject: $(openssl x509 -in "${CA_CRT}" -noout -subject | sed 's/^subject=//')"
echo "==> CA SHA-256: $(openssl x509 -in "${CA_CRT}" -noout -fingerprint -sha256 | sed 's/^.*=//')"

# ingress-system is normally created by Flux, but this script has to run
# before the Issuer can become Ready, so create it if it is not there yet.
kubectl create namespace "${CA_NAMESPACE}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo "==> restoring ${CA_SECRET} into namespace ${CA_NAMESPACE} on ${EXPECTED_CONTEXT}"
kubectl -n "${CA_NAMESPACE}" create secret tls "${CA_SECRET}" \
  --cert="${CA_CRT}" --key="${CA_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo
echo "Development CA installed on home-k3s. Same root dev-kind trusts —"
echo "a client that already trusts it trusts home-k3s's certificates too."
echo "This is a development CA. It is not publicly trusted and must not"
echo "be treated as production PKI."
