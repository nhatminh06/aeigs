#!/usr/bin/env bash
# Installs Cilium as the CNI for aegis-dev. Must run after
# scripts/cluster-up.sh and before scripts/bootstrap-flux.sh.
#
# Cilium is installed here rather than by Flux on purpose: Flux's own
# controllers need a working pod network to reconcile anything, so making
# Flux responsible for the CNI creates a dependency loop where a broken
# Cilium leaves no working path to fix it. See
# docs/decisions/0010-bootstrap-cilium-outside-flux.md.
#
# Safe to re-run: helm upgrade --install is idempotent.
set -euo pipefail

CLUSTER_NAME="aegis-dev"
EXPECTED_CONTEXT="kind-${CLUSTER_NAME}"

# Pinned: Cilium 1.20 is the only stable line that lists Kubernetes 1.36
# (this repo's pinned baseline) as e2e tested — 1.19 covers 1.31-1.34.
CILIUM_VERSION="1.20.0"
CILIUM_IMAGE="quay.io/cilium/cilium:v${CILIUM_VERSION}"
# Cilium's Gateway API requires these CRDs to exist first; it does not
# ship them. Pinned to the version Cilium 1.20 documents.
GATEWAY_API_VERSION="v1.6.1"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CILIUM_VALUES="${REPO_ROOT}/bootstrap/cilium/values.yaml"

for cmd in kubectl helm; do
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

# Gateway API CRDs are applied from pinned raw manifests rather than a
# release tarball because that is the form upstream publishes; the version
# is fixed above so a rebuild installs the same API surface.
echo "==> installing Gateway API CRDs ${GATEWAY_API_VERSION}"
gw_base="https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/${GATEWAY_API_VERSION}/config/crd"
for crd in gatewayclasses gateways httproutes referencegrants grpcroutes backendtlspolicies; do
  kubectl apply -f "${gw_base}/standard/gateway.networking.k8s.io_${crd}.yaml"
done
kubectl apply -f "${gw_base}/experimental/gateway.networking.k8s.io_tlsroutes.yaml"

# With kubeProxyMode: none there is no kube-proxy to provide the API
# server's cluster IP, so Cilium needs its real address. Resolved from the
# live node rather than hard-coded, since kind assigns it at creation.
k8s_service_host="$(kubectl get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
if [ -z "${k8s_service_host}" ]; then
  echo "error: could not determine the node InternalIP for k8sServiceHost" >&2
  exit 1
fi

# The upstream kind guide suggests preloading the image with
# `kind load docker-image`, which passes --all-platforms. On an arm64 host
# `docker pull` only fetches the arm64 layers, so that import fails with a
# missing content digest. Letting the node pull the image itself works on
# both architectures, at the cost of a pull on first install.
echo "==> installing Cilium ${CILIUM_VERSION} (${CILIUM_IMAGE})"
echo "    apiserver: ${k8s_service_host}:6443"
helm repo add cilium https://helm.cilium.io/ >/dev/null
helm repo update cilium >/dev/null
helm upgrade --install cilium cilium/cilium \
  --version "${CILIUM_VERSION}" \
  --namespace kube-system \
  --values "${CILIUM_VALUES}" \
  --set k8sServiceHost="${k8s_service_host}" \
  --set k8sServicePort=6443 \
  --wait --timeout 5m

echo "==> waiting for Cilium and CoreDNS"
kubectl -n kube-system rollout status daemonset/cilium --timeout=300s
kubectl -n kube-system rollout status deployment/cilium-operator --timeout=300s
kubectl -n kube-system rollout status deployment/hubble-relay --timeout=300s
kubectl -n kube-system rollout status deployment/coredns --timeout=300s
kubectl wait --for=condition=Ready node --all --timeout=300s

echo
echo "Cilium ${CILIUM_VERSION} is running and the node is Ready."
echo "Next: scripts/bootstrap-flux.sh"
