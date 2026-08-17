#!/usr/bin/env bash
# Restores the Aegis development CA into the cluster so cert-manager can
# issue certificates for the Gateway hostnames.
#
# The CA private key is the second thing that cannot be rebuilt from Git,
# alongside the age key. It deliberately lives OUTSIDE this repository: Git
# holds public configuration and age-encrypted application secrets, and a
# TLS trust root is neither. Keeping it out also keeps the two trust
# domains separate — the age key decrypts Git secrets, this key signs
# certificates, and compromising one must not yield the other.
#
# Default mode RESTORES an existing CA. Generating a new one is opt-in via
# --init, for the same reason bootstrap-flux.sh refuses to run age-keygen:
# a fresh CA during ordinary cluster recovery silently invalidates every
# client that already trusts the old one, and the failure appears later as
# certificate errors rather than as a bootstrap failure.
#
# Safe to re-run: restore is an idempotent recreate.
set -euo pipefail

CLUSTER_NAME="aegis-dev"
EXPECTED_CONTEXT="kind-${CLUSTER_NAME}"
# Certificates are only consumed by the Gateway, so the Issuer is namespaced
# there and reads its CA from the same namespace.
CA_NAMESPACE="gateway"
CA_SECRET="aegis-dev-ca"
PKI_DIR="${AEGIS_PKI_DIR:-${HOME}/.config/aegis/pki}"
CA_KEY="${PKI_DIR}/ca.key"
CA_CRT="${PKI_DIR}/ca.crt"
# Five years: long enough that a dev CA is not a recurring chore, short
# enough that it is not effectively permanent.
CA_DAYS=1825
CA_SUBJECT="/CN=Aegis Development Root CA/O=Aegis/OU=Development Only"

INIT=0
for arg in "$@"; do
  case "${arg}" in
    --init) INIT=1 ;;
    *) echo "usage: $0 [--init]" >&2; exit 1 ;;
  esac
done

for cmd in kubectl openssl; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "error: required command '${cmd}' not found on PATH" >&2
    exit 1
  fi
done

current_context="$(kubectl config current-context 2>/dev/null || true)"
if [ "${current_context}" != "${EXPECTED_CONTEXT}" ]; then
  echo "error: kubectl context is '${current_context}', expected '${EXPECTED_CONTEXT}'" >&2
  echo "       run: kubectl config use-context ${EXPECTED_CONTEXT}" >&2
  exit 1
fi

if [ -f "${CA_KEY}" ] && [ -f "${CA_CRT}" ]; then
  if [ "${INIT}" -eq 1 ]; then
    echo "error: --init requested but a CA already exists at ${PKI_DIR}" >&2
    echo "       refusing to overwrite it; every client trusting the current" >&2
    echo "       CA would stop trusting this cluster" >&2
    exit 1
  fi
  echo "==> using existing development CA at ${PKI_DIR}"
elif [ "${INIT}" -eq 1 ]; then
  echo "==> generating a NEW development CA at ${PKI_DIR}"
  # 0700 before anything is written, so the key is never briefly readable.
  mkdir -p "${PKI_DIR}"
  chmod 700 "${PKI_DIR}"
  umask 077
  # -nodes: cert-manager needs to read this key unattended, so a passphrase
  # would have to be stored next to it and would protect nothing.
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -nodes -days "${CA_DAYS}" -subj "${CA_SUBJECT}" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -keyout "${CA_KEY}" -out "${CA_CRT}" 2>/dev/null
  chmod 600 "${CA_KEY}"
  chmod 644 "${CA_CRT}"
else
  echo "error: no development CA found at ${PKI_DIR}" >&2
  echo "       restore it from backup, or create the first one with:" >&2
  echo "         $0 --init" >&2
  echo "       do NOT run --init to recover an existing cluster: a new CA" >&2
  echo "       invalidates every client that already trusts the old one" >&2
  exit 1
fi

# Fail before touching the cluster if the pair does not match. Installing a
# key and certificate from different CAs would let the Issuer come up and
# then produce certificates no client can chain.
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
echo "==> CA expires: $(openssl x509 -in "${CA_CRT}" -noout -enddate | sed 's/^notAfter=//')"
echo "==> CA SHA-256: $(openssl x509 -in "${CA_CRT}" -noout -fingerprint -sha256 | sed 's/^.*=//')"

# The Gateway namespace is normally created by Flux, but this script has to
# run before the Issuer can become Ready, so create it if it is not there yet.
kubectl create namespace "${CA_NAMESPACE}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo "==> restoring ${CA_SECRET} into namespace ${CA_NAMESPACE}"
kubectl -n "${CA_NAMESPACE}" create secret tls "${CA_SECRET}" \
  --cert="${CA_CRT}" --key="${CA_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo
echo "Development CA installed. cert-manager's Issuer signs from this key."
echo
echo "Clients must trust ${CA_CRT} explicitly. For project-local testing:"
echo "  curl --cacert ${CA_CRT} https://grafana.aegis.test"
echo
echo "This is a development CA. It is not publicly trusted and must not be"
echo "treated as production PKI."
