#!/usr/bin/env bash
# Brings Flux up on home-k3s from the manifests already committed in this
# repository, without contacting GitHub as a writer — same reasoning as
# scripts/bootstrap-flux.sh (dev-kind).
#
# Simpler than dev-kind's version: no sops-age secret step, since home-k3s
# has no encrypted secrets in Phase 1 (no Authentik/Grafana/etc. here).
#
# Safe to re-run: every step is an apply.
set -euo pipefail

EXPECTED_CONTEXT="home-k3s"
LOCAL_KUBECONFIG="${HOME}/.kube/home-k3s.yaml"
export KUBECONFIG="${LOCAL_KUBECONFIG}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLUX_DIR="${REPO_ROOT}/clusters/home-k3s/flux-system"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "error: required command 'kubectl' not found on PATH" >&2
  exit 1
fi

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

echo "==> applying committed sync configuration (gotk-sync.yaml)"
kubectl apply -f "${FLUX_DIR}/gotk-sync.yaml"

echo
echo "Flux is installed and pointed at the committed GitRepository, path"
echo "./clusters/home-k3s. No GitHub credential was used or created; the"
echo "GitRepository reads this public repository anonymously."
echo
echo "Watch reconciliation with:  KUBECONFIG=${LOCAL_KUBECONFIG} flux get kustomizations --watch"
