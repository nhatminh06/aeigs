#!/usr/bin/env bash
# Fetches home-k3s's kubeconfig from the host over SSH into a fully
# separate local file — never merged into ~/.kube/config, so there is no
# way to accidentally point a kind-aegis-dev command at home-k3s or vice
# versa (every home-k3s script requires KUBECONFIG=this file AND checks
# the resulting current-context).
#
# Requires scripts/bootstrap-home-k3s.sh to have already run on the host
# (write-kubeconfig-mode: "644" is what makes this file readable without a
# second sudo round-trip).
#
# Safe to re-run: overwrites the local file each time.
set -euo pipefail

HOST_ALIAS="cachyos"
REMOTE_KUBECONFIG="/etc/rancher/k3s/k3s.yaml"
LOCAL_KUBECONFIG="${HOME}/.kube/home-k3s.yaml"
CONTEXT_NAME="home-k3s"

for cmd in ssh scp; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "error: required command '${cmd}' not found on PATH" >&2
    exit 1
  fi
done

host_ip="$(ssh -o BatchMode=yes -o ConnectTimeout=8 "${HOST_ALIAS}" \
  "ip -4 addr show tailscale0 | grep -oE 'inet [0-9.]+' | cut -d' ' -f2")"
if [ -z "${host_ip}" ]; then
  echo "error: could not determine ${HOST_ALIAS}'s tailscale0 IP" >&2
  exit 1
fi

mkdir -p "$(dirname "${LOCAL_KUBECONFIG}")"
scp -q "${HOST_ALIAS}:${REMOTE_KUBECONFIG}" "${LOCAL_KUBECONFIG}"
chmod 600 "${LOCAL_KUBECONFIG}"

# Rewrite in place: point at the host's Tailscale IP instead of
# 127.0.0.1, and rename cluster/context/user away from k3s's defaults
# so this file can never collide with ~/.kube/config's kind-aegis-dev
# entries even if someone later merges them by hand.
sed -i '' \
  -e "s#server: https://127.0.0.1:6443#server: https://${host_ip}:6443#" \
  -e "s/name: default/name: ${CONTEXT_NAME}/g" \
  -e "s/cluster: default/cluster: ${CONTEXT_NAME}/g" \
  -e "s/user: default/user: ${CONTEXT_NAME}/g" \
  -e "s/current-context: default/current-context: ${CONTEXT_NAME}/g" \
  "${LOCAL_KUBECONFIG}"

echo "==> wrote ${LOCAL_KUBECONFIG} (mode 600, context '${CONTEXT_NAME}', server ${host_ip}:6443)"
echo "==> verifying"
KUBECONFIG="${LOCAL_KUBECONFIG}" kubectl config current-context
KUBECONFIG="${LOCAL_KUBECONFIG}" kubectl get nodes
