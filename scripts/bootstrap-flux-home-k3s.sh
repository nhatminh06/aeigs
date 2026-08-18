#!/usr/bin/env bash
# Brings Flux up on home-k3s from the manifests already committed in this
# repository, without contacting GitHub as a writer — same reasoning as
# scripts/bootstrap-flux.sh (dev-kind).
#
# Restores the same sops-age secret dev-kind's bootstrap script does
# (needed since stateful-lab/postgresql/secret.enc.yaml — the first
# encrypted secret on this cluster); everything else stays simpler than
# dev-kind's version since there's no other encrypted state here.
#
# Safe to re-run: every step is an apply or an idempotent recreate.
#
# AEGIS_HOME_K3S_KUBECONFIG / AEGIS_HOME_K3S_CONTEXT: same purpose as in
# scripts/bootstrap-cilium-home-k3s.sh — lets this script safely target a
# replacement-host reconstruction test without risking the primary
# cluster's kubeconfig. Unset, behavior is unchanged.
set -euo pipefail

EXPECTED_CONTEXT="${AEGIS_HOME_K3S_CONTEXT:-home-k3s}"
LOCAL_KUBECONFIG="${AEGIS_HOME_K3S_KUBECONFIG:-${HOME}/.kube/home-k3s.yaml}"
export KUBECONFIG="${LOCAL_KUBECONFIG}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLUX_DIR="${REPO_ROOT}/clusters/home-k3s/flux-system"
AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-${HOME}/.config/sops/age/keys.txt}"

for cmd in kubectl age-keygen; do
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

# Same key dev-kind restores from — one age keypair for the whole repo,
# not one per cluster. Catches a wrong/missing key before any encrypted
# Kustomization gets a chance to fail opaquely.
if [ ! -f "${AGE_KEY_FILE}" ]; then
  echo "error: age private key not found at '${AGE_KEY_FILE}'" >&2
  echo "       restore it from backup; do NOT run age-keygen (a new key" >&2
  echo "       cannot decrypt the existing *.enc.yaml files)" >&2
  exit 1
fi
key_recipient="$(age-keygen -y "${AGE_KEY_FILE}" 2>/dev/null || true)"
sops_recipient="$(grep -o 'age1[a-z0-9]*' "${REPO_ROOT}/.sops.yaml" | head -1)"
if [ -z "${key_recipient}" ]; then
  echo "error: could not derive a public key from '${AGE_KEY_FILE}'" >&2
  exit 1
fi
if [ "${key_recipient}" != "${sops_recipient}" ]; then
  echo "error: age key does not match the recipient in .sops.yaml" >&2
  echo "       key file : ${key_recipient}" >&2
  echo "       .sops.yaml: ${sops_recipient}" >&2
  exit 1
fi
echo "==> age key matches .sops.yaml recipient (${key_recipient})"

echo "==> restoring sops-age secret from ${AGE_KEY_FILE}"
kubectl -n flux-system create secret generic sops-age \
  --from-file=age.agekey="${AGE_KEY_FILE}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> applying committed sync configuration (gotk-sync.yaml)"
kubectl apply -f "${FLUX_DIR}/gotk-sync.yaml"

echo
echo "Flux is installed and pointed at the committed GitRepository, path"
echo "./clusters/home-k3s. No GitHub credential was used or created; the"
echo "GitRepository reads this public repository anonymously."
echo
echo "Watch reconciliation with:  KUBECONFIG=${LOCAL_KUBECONFIG} flux get kustomizations --watch"
