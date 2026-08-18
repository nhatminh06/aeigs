#!/usr/bin/env bash
# Installs K3s on the persistent home-k3s host. Run THIS SCRIPT ON THE
# LINUX HOST ITSELF (e.g. `ssh cachyos`, copy this file over, then run it
# there) — never on macOS, and never remotely with sudo piped through SSH,
# since that needs an interactive password this script deliberately does
# not try to supply.
#
# Cilium and Flux are bootstrapped separately, from the operator's own
# machine against this host's API server — see
# scripts/bootstrap-cilium-home-k3s.sh and scripts/bootstrap-flux-home-k3s.sh.
# K3s is installed here, alone, because it's the one step that genuinely
# needs root on this specific host.
#
# Safe to re-run: config.yaml is rewritten idempotently, and the K3s
# installer is idempotent for an already-installed matching version.
set -euo pipefail

K3S_VERSION="v1.36.3+k3s1"
CONFIG_DIR="/etc/rancher/k3s"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"

if [ "$(uname -s)" != "Linux" ]; then
  echo "error: this script installs K3s and must run on Linux, not $(uname -s)" >&2
  echo "       K3s does not run on macOS; see docs/decisions/0013-home-k3s-persistent-environment.md" >&2
  exit 1
fi

if [ "$(id -u)" -eq 0 ]; then
  echo "error: run this as your normal user, not root — it calls sudo itself where needed" >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "error: required command 'curl' not found on PATH" >&2
  exit 1
fi

echo "==> this script will use sudo to write ${CONFIG_FILE} and install the k3s systemd service"
echo "    you will be prompted for your password"

# Written BEFORE the installer runs, so the first start already reads it —
# avoids a second install/restart cycle just to apply config.
#
# flannel-backend: none        — Cilium owns the CNI; no dual-CNI conflict.
# disable-network-policy: true — Cilium enforces NetworkPolicy; K3s's own
#                                 controller would just be a second,
#                                 redundant enforcement path.
# disable: [traefik]           — Aegis standardizes on Cilium Gateway API
#                                 for HTTP routing (dev-kind already does);
#                                 running two ingress systems on one node
#                                 buys nothing and Traefik isn't used here.
# write-kubeconfig-mode: "644" — lets the operator's own machine fetch
#                                 /etc/rancher/k3s/k3s.yaml over SSH
#                                 without a second sudo round-trip.
#                                 Tradeoff: any local user on this host can
#                                 then read a cluster-admin credential —
#                                 accepted here because this is a
#                                 single-user personal machine; revisit if
#                                 that ever changes.
# disable-kube-proxy: true     — required for Cilium's kube-proxy-replacement
#                                 mode. Originally left out here and added
#                                 live, by hand, after a real failure:
#                                 leaving K3s's kube-proxy running alongside
#                                 Cilium left Service ClusterIPs reachable
#                                 from the host network but NOT from the pod
#                                 network, so CoreDNS could never sync
#                                 against the API server and sat 0/1 Ready
#                                 indefinitely. That live fix was never fed
#                                 back into this script until a
#                                 replacement-host reconstruction test
#                                 exposed the gap — see
#                                 bootstrap/cilium/home-k3s-values.yaml and
#                                 docs/decisions/0013-home-k3s-persistent-environment.md.
#
# Traefik/Flannel/NetworkPolicy/kube-proxy aside, nothing else is disabled
# — ServiceLB, local-path-provisioner, and metrics-server all stay at K3s's
# defaults. See
# docs/decisions/0013-home-k3s-persistent-environment.md for the reasoning
# behind every one of these.
sudo mkdir -p "${CONFIG_DIR}"
sudo tee "${CONFIG_FILE}" > /dev/null <<'EOF'
flannel-backend: "none"
disable-network-policy: true
disable:
  - traefik
write-kubeconfig-mode: "644"
disable-kube-proxy: true
EOF
echo "==> wrote ${CONFIG_FILE}"

echo "==> installing K3s ${K3S_VERSION} (pinned, not latest)"
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${K3S_VERSION}" sh -

echo "==> waiting for the K3s API server"
# shellcheck disable=SC2034
for i in $(seq 1 30); do
  if sudo k3s kubectl get --raw='/readyz' >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

echo
echo "K3s ${K3S_VERSION} installed."
echo "Node status (NotReady is expected here — no CNI installed yet):"
sudo k3s kubectl get nodes
echo
echo "Next: from the operator machine, run scripts/fetch-home-k3s-kubeconfig.sh"
echo "then scripts/bootstrap-cilium-home-k3s.sh"
