#!/usr/bin/env bash
# Verifies SOPS key ownership without printing private key or decrypted values.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-${HOME}/.config/sops/age/keys.txt}"
TEST_MANIFEST="${1:-${REPO_ROOT}/apps/demo-app/secret.enc.yaml}"

for cmd in age-keygen sops; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "error: required command '${cmd}' not found on PATH" >&2
    exit 1
  fi
done

if [ ! -f "${AGE_KEY_FILE}" ]; then
  echo "error: SOPS age key not found at '${AGE_KEY_FILE}'" >&2
  exit 1
fi
if [ ! -f "${TEST_MANIFEST}" ]; then
  echo "error: encrypted test manifest not found at '${TEST_MANIFEST}'" >&2
  exit 1
fi

expected_recipient="$(grep -o 'age1[a-z0-9]*' "${REPO_ROOT}/.sops.yaml" | head -1)"
actual_recipient="$(age-keygen -y "${AGE_KEY_FILE}" 2>/dev/null || true)"
if [ -z "${expected_recipient}" ] || [ "${actual_recipient}" != "${expected_recipient}" ]; then
  echo "error: age key does not match the recipient in .sops.yaml" >&2
  exit 1
fi

SOPS_AGE_KEY_FILE="${AGE_KEY_FILE}" sops --decrypt "${TEST_MANIFEST}" >/dev/null
echo "SOPS key recipient matches and test decryption succeeded."
