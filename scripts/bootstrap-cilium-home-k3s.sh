#!/usr/bin/env bash
# Installs Cilium as the CNI for home-k3s. Must run after
# scripts/bootstrap-home-k3s.sh (on the host) and
# scripts/fetch-home-k3s-kubeconfig.sh (here), and before
# scripts/bootstrap-flux-home-k3s.sh.
#
# Same reasoning as scripts/bootstrap-cilium.sh (dev-kind): installed here
# rather than by Flux, because Flux's own controllers need a working pod
# network to reconcile anything at all. See
# docs/decisions/0010-bootstrap-cilium-outside-flux.md (dev-kind) and
# docs/decisions/0013-home-k3s-persistent-environment.md (home-k3s).
#
# Safe to re-run: helm upgrade --install is idempotent.
set -euo pipefail

EXPECTED_CONTEXT="home-k3s"
LOCAL_KUBECONFIG="${HOME}/.kube/home-k3s.yaml"
export KUBECONFIG="${LOCAL_KUBECONFIG}"

# Same version dev-kind uses — already documented there as e2e-tested
# against Kubernetes 1.36, which is what K3s v1.36.3+k3s1 runs too.
CILIUM_VERSION="1.20.0"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CILIUM_VALUES="${REPO_ROOT}/bootstrap/cilium/home-k3s-values.yaml"

for cmd in kubectl helm; do
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

# With kube-proxy disabled on the host (disable-kube-proxy: true in
# /etc/rancher/k3s/config.yaml), there is no kube-proxy to provide the API
# server's ClusterIP, so Cilium needs its real address — same reasoning
# as scripts/bootstrap-cilium.sh (dev-kind).
k8s_service_host="$(kubectl get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
if [ -z "${k8s_service_host}" ]; then
  echo "error: could not determine the node InternalIP for k8sServiceHost" >&2
  exit 1
fi

echo "==> installing Cilium ${CILIUM_VERSION} on ${EXPECTED_CONTEXT}"
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
kubectl -n kube-system rollout status deployment/coredns --timeout=300s
kubectl wait --for=condition=Ready node --all --timeout=300s

echo "==> verifying in-cluster DNS resolution"
# Fully qualified: this pod's own exec context doesn't apply the search
# domain busybox's nslookup would normally get from /etc/resolv.conf.
kubectl run dns-check --rm -i --restart=Never --image=busybox:1.36 --command --timeout=60s \
  -- nslookup kubernetes.default.svc.cluster.local

echo
echo "Cilium ${CILIUM_VERSION} is running and the node is Ready."
echo "Next: scripts/bootstrap-flux-home-k3s.sh"
