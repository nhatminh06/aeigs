#!/usr/bin/env bash
# Brings Flux up on aegis-dev from the manifests already committed in this
# repository, without contacting GitHub as a writer.
#
# Deliberately NOT `flux bootstrap github --token-auth`: that command
# "commits the Flux manifests to the specified branch" (its own --help),
# so re-running it on a rebuild regenerates gotk-sync.yaml with a
# token-backed secretRef and pushes that to main — silently undoing the
# runtime-credential hardening in
# docs/decisions/0009-minimize-runtime-git-credentials.md. Applying the
# committed manifests instead needs no GitHub token at all and cannot
# mutate the repository.
#
# Safe to re-run: every step is an apply or an idempotent recreate.
set -euo pipefail

CLUSTER_NAME="aegis-dev"
EXPECTED_CONTEXT="kind-${CLUSTER_NAME}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLUX_DIR="${REPO_ROOT}/clusters/dev-kind/flux-system"
AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-${HOME}/.config/sops/age/keys.txt}"

# age-keygen is required, not optional: it is the only way to check the
# restored key actually decrypts this repo before the secret is created.
# Continuing without that check is how a wrong key gets installed silently.
for cmd in kubectl age-keygen; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "error: required command '${cmd}' not found on PATH" >&2
    exit 1
  fi
done

# Guard against applying cluster-wide resources to the wrong cluster —
# other kind clusters may exist on this machine.
current_context="$(kubectl config current-context 2>/dev/null || true)"
if [ "${current_context}" != "${EXPECTED_CONTEXT}" ]; then
  echo "error: kubectl context is '${current_context}', expected '${EXPECTED_CONTEXT}'" >&2
  echo "       run: kubectl config use-context ${EXPECTED_CONTEXT}" >&2
  exit 1
fi

# The age private key is the one thing that cannot be rebuilt from Git: it
# decrypts every *.enc.yaml. This must be the EXISTING key matching
# .sops.yaml's recipient — generating a fresh one leaves the encrypted
# manifests permanently undecryptable.
if [ ! -f "${AGE_KEY_FILE}" ]; then
  echo "error: age private key not found at '${AGE_KEY_FILE}'" >&2
  echo "       restore it from backup; do NOT run age-keygen (a new key" >&2
  echo "       cannot decrypt the existing *.enc.yaml files)" >&2
  exit 1
fi

# Catch the wrong key early. Restoring a valid-but-unrelated age key would
# bootstrap "successfully" and only fail later as opaque decryption errors
# on the apps/identity/observability Kustomizations. Compares public
# halves only — the private key is never read into a variable or printed.
key_recipient="$(age-keygen -y "${AGE_KEY_FILE}" 2>/dev/null || true)"
sops_recipient="$(grep -o 'age1[a-z0-9]*' "${REPO_ROOT}/.sops.yaml" | head -1)"
if [ -z "${key_recipient}" ]; then
  echo "error: could not derive a public key from '${AGE_KEY_FILE}'" >&2
  echo "       the file may be corrupt or not an age key" >&2
  exit 1
fi
if [ "${key_recipient}" != "${sops_recipient}" ]; then
  echo "error: age key does not match the recipient in .sops.yaml" >&2
  echo "       key file : ${key_recipient}" >&2
  echo "       .sops.yaml: ${sops_recipient}" >&2
  echo "       this key cannot decrypt this repository's secrets" >&2
  exit 1
fi
echo "==> age key matches .sops.yaml recipient (${key_recipient})"

echo "==> installing Flux controllers (committed gotk-components.yaml)"
kubectl apply -f "${FLUX_DIR}/gotk-components.yaml"

echo "==> waiting for Flux CRDs to be established"
kubectl wait --for=condition=Established --timeout=120s \
  crd/gitrepositories.source.toolkit.fluxcd.io \
  crd/kustomizations.kustomize.toolkit.fluxcd.io \
  crd/helmreleases.helm.toolkit.fluxcd.io \
  crd/helmrepositories.source.toolkit.fluxcd.io

echo "==> waiting for Flux controllers to be available"
kubectl -n flux-system wait --for=condition=Available --timeout=300s deployment --all

# Created before the sync manifests so the encrypted Kustomizations can
# decrypt on their first reconcile attempt rather than erroring first.
echo "==> restoring sops-age secret from ${AGE_KEY_FILE}"
kubectl -n flux-system create secret generic sops-age \
  --from-file=age.agekey="${AGE_KEY_FILE}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> applying committed sync configuration (gotk-sync.yaml)"
kubectl apply -f "${FLUX_DIR}/gotk-sync.yaml"

echo
echo "Flux is installed and pointed at the committed GitRepository."
echo "No GitHub credential was used or created; the GitRepository reads"
echo "this public repository anonymously."
echo
echo "Watch reconciliation with:  flux get kustomizations --watch"
