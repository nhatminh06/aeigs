#!/usr/bin/env bash
# Creates the local aegis-dev kind cluster. Safe to re-run: exits early if
# the cluster already exists instead of erroring on a duplicate name.
set -euo pipefail

CLUSTER_NAME="aegis-dev"
CONFIG_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bootstrap/kind/cluster.yaml"

for cmd in docker kind kubectl; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "error: required command '${cmd}' not found on PATH" >&2
    exit 1
  fi
done

if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  echo "cluster '${CLUSTER_NAME}' already exists, skipping creation"
  exit 0
fi

kind create cluster --config "${CONFIG_FILE}"
kubectl cluster-info --context "kind-${CLUSTER_NAME}"
