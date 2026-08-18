#!/usr/bin/env bash
# Datapath-isolation control experiment for
# docs/decisions/0014-home-k3s-gateway-blocked-by-cilium-ingress-identity-bug.md.
#
# Applies an ordinary nginx reverse proxy (never through Cilium's Gateway
# API) in front of aegis-api, first pod-to-pod (ClusterIP), then patched
# to NodePort for an external-exposure check. This answers one question:
# does *any* proxy-to-aegis-api path on this host work, or only the
# Gateway/reserved:ingress one is broken?
#
# Always tears itself down (trap EXIT), unless --keep is passed for live
# debugging. Safe to re-run — kubectl apply is idempotent.
#
# Usage: AEGIS_HOME_K3S_CONTEXT=home-k3s scripts_dir/test.sh [--keep]
set -euo pipefail

EXPECTED_CONTEXT="${AEGIS_HOME_K3S_CONTEXT:-home-k3s}"
LOCAL_KUBECONFIG="${AEGIS_HOME_K3S_KUBECONFIG:-${HOME}/.kube/home-k3s.yaml}"
export KUBECONFIG="${LOCAL_KUBECONFIG}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFESTS_DIR="${REPO_ROOT}/ingress-lab/manifests"
NS="ingress-lab"
KEEP=0
for arg in "$@"; do
  case "${arg}" in
    --keep) KEEP=1 ;;
    *) echo "usage: $0 [--keep]" >&2; exit 1 ;;
  esac
done

if ! command -v kubectl >/dev/null 2>&1; then
  echo "error: required command 'kubectl' not found on PATH" >&2
  exit 1
fi

current_context="$(kubectl config current-context 2>/dev/null || true)"
if [ "${current_context}" != "${EXPECTED_CONTEXT}" ]; then
  echo "error: kubectl context is '${current_context}', expected '${EXPECTED_CONTEXT}'" >&2
  exit 1
fi

cleanup() {
  if [ "${KEEP}" -eq 1 ]; then
    echo "==> --keep set: leaving ${NS} live for manual inspection"
    echo "    remove later with: kubectl delete -k ${MANIFESTS_DIR}"
    return
  fi
  echo "==> tearing down ${NS}"
  kubectl delete -k "${MANIFESTS_DIR}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> applying ${NS} manifests"
kubectl apply -k "${MANIFESTS_DIR}"
kubectl -n "${NS}" rollout status deployment/ingress-lab-proxy --timeout=60s

probe() {
  local url="$1"
  kubectl -n "${NS}" run "ingress-lab-probe-$$" --rm -i --restart=Never --quiet \
    --image=busybox:1.36 --command --timeout=15s -- \
    wget -qO- -T 5 -S "${url}" 2>&1 | grep -E "^  HTTP|^HTTP" | head -1 || echo "  (no response)"
}

echo "==> pod-to-pod: probe pod -> proxy Service -> aegis-api"
for path in /healthz /readyz /api/v1/info; do
  echo "-- GET http://ingress-lab-proxy.${NS}.svc.cluster.local:8080${path}"
  probe "http://ingress-lab-proxy.${NS}.svc.cluster.local:8080${path}"
done
echo "-- GET .../metrics (expect no location match / non-2xx)"
probe "http://ingress-lab-proxy.${NS}.svc.cluster.local:8080/metrics" || true

echo "==> patching Service to NodePort for external-exposure phase"
kubectl -n "${NS}" patch service ingress-lab-proxy -p '{"spec":{"type":"NodePort"}}' >/dev/null
node_port="$(kubectl -n "${NS}" get service ingress-lab-proxy -o jsonpath='{.spec.ports[0].nodePort}')"
node_ip="$(kubectl get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
echo "==> NodePort assigned: ${node_ip}:${node_port}"
echo "    run the external check manually, e.g.:"
printf '      ssh cachyos curl -s -o /dev/null -w "%%{http_code}\\n" http://127.0.0.1:%s/healthz\n' "${node_port}"
