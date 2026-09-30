#!/usr/bin/env bash
# Canonical static repository verification for both local development and CI.
# This script renders manifests only; it never contacts a Kubernetes cluster or
# decrypts SOPS-encrypted values.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

SHELLCHECK_BIN="${SHELLCHECK_BIN:-shellcheck}"
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
KUBECONFORM_BIN="${KUBECONFORM_BIN:-kubeconform}"
KYVERNO_BIN="${KYVERNO_BIN:-kyverno}"
GITLEAKS_BIN="${GITLEAKS_BIN:-gitleaks}"
TRIVY_BIN="${TRIVY_BIN:-trivy}"
DOCKER_BIN="${DOCKER_BIN:-docker}"

KUBERNETES_SCHEMA_COMMIT="${KUBERNETES_SCHEMA_COMMIT:-a6f9a32d2ccb64b6e4f5b41419b9c2e8ee0cce18}"
FLUX_SCHEMA_DIR="${FLUX_SCHEMA_DIR:-}"
RENOVATE_IMAGE="ghcr.io/renovatebot/renovate:44.30.3@sha256:d3d60a87bab73203327dd664f94f11e83091441ee4964c920662d83023446395"

TMP_DIR=""
cleanup() {
  if [ -n "${TMP_DIR}" ] && [ -d "${TMP_DIR}" ]; then
    rm -rf "${TMP_DIR}"
  fi
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
usage: scripts/verify-repo.sh [stage]

With no stage, run the complete static repository verification suite.
CI may select one canonical stage to retain separate, diagnosable jobs:
  shellcheck | kyverno | manifests | gitleaks | trivy | renovate | hygiene
EOF
}

have_tool() {
  local tool="$1"
  if [[ "${tool}" == */* ]]; then
    [ -x "${tool}" ]
  else
    command -v "${tool}" >/dev/null 2>&1
  fi
}

require_tool() {
  local name="$1" tool="$2"
  if ! have_tool "${tool}"; then
    echo "error: required command '${name}' not found (configured as '${tool}')" >&2
    exit 1
  fi
}

stage() {
  local label="$1"
  shift
  echo
  echo "==> ${label}"
  "$@"
  echo "PASS: ${label}"
}

verify_shellcheck() {
  require_tool shellcheck "${SHELLCHECK_BIN}"
  "${SHELLCHECK_BIN}" scripts/*.sh
}

verify_prerequisites() {
  require_tool shellcheck "${SHELLCHECK_BIN}"
  require_tool kubectl "${KUBECTL_BIN}"
  require_tool kubeconform "${KUBECONFORM_BIN}"
  require_tool kyverno "${KYVERNO_BIN}"
  require_tool gitleaks "${GITLEAKS_BIN}"
  require_tool docker "${DOCKER_BIN}"
  require_tool git git
  if [ -z "${FLUX_SCHEMA_DIR}" ]; then
    echo "error: FLUX_SCHEMA_DIR must point to extracted official Flux CRD schemas" >&2
    exit 1
  fi
  if [ ! -d "${FLUX_SCHEMA_DIR}" ]; then
    echo "error: FLUX_SCHEMA_DIR is not a directory: ${FLUX_SCHEMA_DIR}" >&2
    exit 1
  fi
}

verify_kyverno() {
  require_tool kyverno "${KYVERNO_BIN}"
  "${KYVERNO_BIN}" test security/policies/tests
}

prepare_manifests() {
  require_tool kubectl "${KUBECTL_BIN}"
  require_tool kubeconform "${KUBECONFORM_BIN}"
  if [ -z "${FLUX_SCHEMA_DIR}" ]; then
    echo "error: FLUX_SCHEMA_DIR must point to extracted official Flux CRD schemas" >&2
    exit 1
  fi
  if [ ! -d "${FLUX_SCHEMA_DIR}" ]; then
    echo "error: FLUX_SCHEMA_DIR is not a directory: ${FLUX_SCHEMA_DIR}" >&2
    exit 1
  fi
  FLUX_SCHEMA_DIR="$(cd "${FLUX_SCHEMA_DIR}" && pwd)"
  TMP_DIR="$(mktemp -d)"
}

render_environment() {
  local environment="$1"
  "${KUBECTL_BIN}" kustomize "clusters/${environment}" >"${TMP_DIR}/${environment}.yaml"
}

validate_environment() {
  local environment="$1"
  "${KUBECONFORM_BIN}" \
    -strict \
    -summary \
    -kubernetes-version 1.36.0 \
    -schema-location "https://raw.githubusercontent.com/yannh/kubernetes-json-schema/${KUBERNETES_SCHEMA_COMMIT}/{{.NormalizedKubernetesVersion}}-standalone{{.StrictSuffix}}/{{.ResourceKind}}{{.KindSuffix}}.json" \
    -schema-location "file://${FLUX_SCHEMA_DIR}/{{.ResourceKind}}{{.KindSuffix}}.json" \
    -skip CustomResourceDefinition \
    "${TMP_DIR}/${environment}.yaml"
}

verify_manifests() {
  prepare_manifests
  stage "Render dev-kind" render_environment dev-kind
  stage "Render home-k3s" render_environment home-k3s
  stage "Validate dev-kind schemas" validate_environment dev-kind
  stage "Validate home-k3s schemas" validate_environment home-k3s
}

verify_gitleaks() {
  require_tool gitleaks "${GITLEAKS_BIN}"
  "${GITLEAKS_BIN}" detect --source . --redact --exit-code 1
}

verify_trivy_required() {
  require_tool trivy "${TRIVY_BIN}"
  "${TRIVY_BIN}" config --config trivy.yaml .
}

verify_trivy_optional() {
  echo
  echo "==> Trivy configuration scan"
  if have_tool "${TRIVY_BIN}"; then
    "${TRIVY_BIN}" config --config trivy.yaml .
    echo "PASS: Trivy configuration scan"
  else
    echo "SKIP: trivy is not installed locally; the pinned CI Trivy action remains required"
  fi
}

verify_renovate() {
  require_tool docker "${DOCKER_BIN}"
  "${DOCKER_BIN}" run --rm -v "${REPO_ROOT}:/work:ro" -w /work \
    "${RENOVATE_IMAGE}" renovate-config-validator
}

verify_hygiene() {
  require_tool git git
  git diff --check
  if [ -n "${VERIFY_DIFF_BASE:-}" ]; then
    git diff --check "${VERIFY_DIFF_BASE}...HEAD"
  fi
}

run_full() {
  stage "Prerequisites" verify_prerequisites
  stage "ShellCheck" verify_shellcheck
  stage "Kyverno policy fixtures" verify_kyverno
  verify_manifests
  stage "Gitleaks" verify_gitleaks
  verify_trivy_optional
  stage "Renovate configuration" verify_renovate
  stage "Git diff hygiene" verify_hygiene
}

if [ "$#" -gt 1 ]; then
  usage >&2
  exit 2
fi

case "${1:-all}" in
  all) run_full ;;
  shellcheck) stage "ShellCheck" verify_shellcheck ;;
  kyverno) stage "Kyverno policy fixtures" verify_kyverno ;;
  manifests) verify_manifests ;;
  gitleaks) stage "Gitleaks" verify_gitleaks ;;
  trivy) stage "Trivy configuration scan" verify_trivy_required ;;
  renovate) stage "Renovate configuration" verify_renovate ;;
  hygiene) stage "Git diff hygiene" verify_hygiene ;;
  -h|--help) usage ;;
  *)
    echo "error: unknown verification stage '$1'" >&2
    usage >&2
    exit 2
    ;;
esac
