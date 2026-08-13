#!/usr/bin/env bash
# DESTRUCTIVE: deletes the local aegis-dev kind cluster and all workloads
# running on it. There is no confirmation prompt — this cluster is meant
# to be disposable.
set -euo pipefail

CLUSTER_NAME="aegis-dev"

if ! command -v kind >/dev/null 2>&1; then
  echo "error: required command 'kind' not found on PATH" >&2
  exit 1
fi

if ! kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  echo "cluster '${CLUSTER_NAME}' does not exist, nothing to do"
  exit 0
fi

kind delete cluster --name "${CLUSTER_NAME}"
