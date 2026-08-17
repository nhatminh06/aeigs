#!/usr/bin/env bash
# Restores the Git write credential that ImageUpdateAutomation uses to
# commit selected aegis-api releases back into this repository.
#
# This is the third thing that cannot be rebuilt from Git, alongside the
# SOPS age key and the development CA — and deliberately kept separate
# from both. It lives outside this repository for the same reason as the
# other two: a credential capable of writing to the repo that could
# itself carry that credential (even SOPS-encrypted) creates a trust
# cycle through whatever already holds the age key. See
# docs/decisions/0012-image-automation-git-write-credential.md.
#
# The credential is a fine-grained GitHub PAT, scoped to only this
# repository with Contents: Read and write and nothing else. Fine-grained
# PATs can only be created through GitHub's web UI (Settings -> Developer
# settings -> Fine-grained tokens), not via API/CLI, so unlike the age key
# or the CA there is no --init path here that generates one — creating
# the token is a manual, one-time step outside this script.
#
# Safe to re-run: restore is an idempotent recreate.
set -euo pipefail

CLUSTER_NAME="aegis-dev"
EXPECTED_CONTEXT="kind-${CLUSTER_NAME}"
SECRET_NAMESPACE="flux-system"
SECRET_NAME="aegis-api-image-writer"
TOKEN_FILE="${AEGIS_IMAGE_WRITER_TOKEN_FILE:-${HOME}/.config/aegis/git-writer/token}"
GITHUB_USER="${AEGIS_GITHUB_USER:-nhatminh06}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "error: required command 'kubectl' not found on PATH" >&2
  exit 1
fi

current_context="$(kubectl config current-context 2>/dev/null || true)"
if [ "${current_context}" != "${EXPECTED_CONTEXT}" ]; then
  echo "error: kubectl context is '${current_context}', expected '${EXPECTED_CONTEXT}'" >&2
  echo "       run: kubectl config use-context ${EXPECTED_CONTEXT}" >&2
  exit 1
fi

if [ ! -f "${TOKEN_FILE}" ]; then
  echo "error: no token found at ${TOKEN_FILE}" >&2
  echo "       create a fine-grained PAT at https://github.com/settings/tokens" >&2
  echo "       scoped to ONLY nhatminh06/aeigs, with Contents: Read and write" >&2
  echo "       and nothing else, then save it to that path with:" >&2
  echo "         mkdir -p \"\$(dirname \"${TOKEN_FILE}\")\" && chmod 700 \"\$(dirname \"${TOKEN_FILE}\")\"" >&2
  echo "         umask 077; cat > \"${TOKEN_FILE}\"   # paste token, then Ctrl-D" >&2
  exit 1
fi

perms="$(stat -f '%Lp' "${TOKEN_FILE}" 2>/dev/null || stat -c '%a' "${TOKEN_FILE}" 2>/dev/null || true)"
if [ -n "${perms}" ] && [ "${perms}" != "600" ]; then
  echo "error: ${TOKEN_FILE} must be mode 600 (found ${perms})" >&2
  echo "       run: chmod 600 ${TOKEN_FILE}" >&2
  exit 1
fi

echo "==> restoring ${SECRET_NAME} into namespace ${SECRET_NAMESPACE}"
# --from-file would embed a trailing newline verbatim if the file has one
# (e.g. from `cat > file` during manual creation), which GitHub rejects
# with the generic "Password authentication is not supported" error —
# indistinguishable from a wrong token unless you already know to check
# for this. Command substitution strips trailing newlines, so read the
# token through that instead of passing the file straight through.
token="$(cat "${TOKEN_FILE}")"
kubectl -n "${SECRET_NAMESPACE}" create secret generic "${SECRET_NAME}" \
  --from-literal=username="${GITHUB_USER}" \
  --from-literal=password="${token}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
unset token

echo
echo "Git write credential installed. GitRepository/aegis-api-image-writer"
echo "can now authenticate; ImageUpdateAutomation/aegis-api can push commits"
echo "once resumed. The token itself is never printed by this script."
echo
echo "This credential is repository-scoped and grants nothing beyond"
echo "Contents: Read and write on nhatminh06/aeigs — not repository admin,"
echo "not other repositories, not organization-level access."
