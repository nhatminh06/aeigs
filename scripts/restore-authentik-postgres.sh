#!/usr/bin/env bash
# Restores an encrypted Authentik PostgreSQL backup (produced by
# scripts/backup-authentik-postgres.sh) into the authentik database on
# home-k3s. Decrypts on the operator's own machine and streams the
# restore into the cluster — the backup private key never needs to exist
# on K3s.
#
# Usage:
#   scripts/restore-authentik-postgres.sh <path-to-.dump.age> [--replace-existing]
#
# The archive is a full pg_dump -Fc of the authentik database (schema +
# data, no --create) — see backup-authentik-postgres.sh. A freshly
# Flux-reconstructed authentik database already has Django's migrated
# schema in it (empty of data, but not empty of objects), so restoring
# without --replace-existing will fail loudly on "already exists" rather
# than silently colliding. --replace-existing drops and recreates the
# database first, then restores into a truly empty one — the only
# restore mode that's safe against Authentik's trigger/function schema
# (pgtrigger creates functions with dependency ordering that --clean
# --if-exists per-object can't reliably unwind).
#
# See docs/runbooks/home-k3s-authentik.md.
#
# AEGIS_HOME_K3S_CONTEXT: same purpose as in
# scripts/bootstrap-cilium-home-k3s.sh — lets this script safely target a
# replacement-host reconstruction test. Unset, behavior is unchanged.
set -euo pipefail
umask 077

EXPECTED_CONTEXT="${AEGIS_HOME_K3S_CONTEXT:-home-k3s}"
NAMESPACE="authentik"
POD="authentik-postgresql-0"
DB_USER="authentik"
DB_NAME="authentik"
BACKUP_KEY_FILE="${AEGIS_BACKUP_AGE_KEY_FILE:-${HOME}/.config/aegis/backup/age/keys.txt}"

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <path-to-.dump.age> [--replace-existing]" >&2
  exit 1
fi
BACKUP_PATH="$1"
REPLACE_EXISTING="${2:-}"

for cmd in kubectl age sha256sum; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "error: required command '${cmd}' not found on PATH" >&2
    exit 1
  fi
done

current_context="$(kubectl config current-context 2>/dev/null || true)"
if [ "${current_context}" != "${EXPECTED_CONTEXT}" ]; then
  echo "error: kubectl context is '${current_context}', expected '${EXPECTED_CONTEXT}'" >&2
  echo "       refusing to restore into a database on the wrong cluster" >&2
  exit 1
fi

if [ ! -f "${BACKUP_PATH}" ]; then
  echo "error: backup file not found: ${BACKUP_PATH}" >&2
  exit 1
fi
if [ ! -f "${BACKUP_KEY_FILE}" ]; then
  echo "error: backup age key not found at '${BACKUP_KEY_FILE}'" >&2
  exit 1
fi

metadata_path="${BACKUP_PATH%.dump.age}.metadata.txt"
if [ -f "${metadata_path}" ]; then
  expected_sha256="$(grep '^encrypted_sha256:' "${metadata_path}" | cut -d' ' -f2)"
  actual_sha256="$(sha256sum "${BACKUP_PATH}" | cut -d' ' -f1)"
  if [ -n "${expected_sha256}" ] && [ "${expected_sha256}" != "${actual_sha256}" ]; then
    echo "error: checksum mismatch for ${BACKUP_PATH}" >&2
    echo "       expected: ${expected_sha256}" >&2
    echo "       actual:   ${actual_sha256}" >&2
    exit 1
  fi
  echo "==> checksum verified against ${metadata_path}"
else
  echo "warning: no metadata file at ${metadata_path}; skipping checksum verification" >&2
fi

plaintext_dump="$(mktemp)"
remote_dump_path="$(kubectl -n "${NAMESPACE}" exec "${POD}" -- mktemp)"
cleanup() {
  rm -f "${plaintext_dump}"
  kubectl -n "${NAMESPACE}" exec "${POD}" -- rm -f "${remote_dump_path}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> decrypting"
if ! age -d -i "${BACKUP_KEY_FILE}" -o "${plaintext_dump}" "${BACKUP_PATH}"; then
  echo "error: decryption failed — wrong key, or the backup file is not valid age ciphertext" >&2
  exit 1
fi

# kubectl exec -i (stdin piping) reliably breaks on Authentik's larger
# dump ("connection reset by peer" over this Tailscale path, reproduced
# consistently) — same workaround as backup-authentik-postgres.sh and
# verify-authentik-backup-restore.sh: copy the plaintext dump into the
# pod's own /tmp first, then exec against that local path instead of
# duplexing a large stdin against stdout.
echo "==> copying dump into pod for restore"
kubectl -n "${NAMESPACE}" cp "${plaintext_dump}" "${POD}:${remote_dump_path}"

echo "==> verifying archive structure (pg_restore --list)"
restore_list_file="$(mktemp)"
kubectl -n "${NAMESPACE}" exec "${POD}" -- pg_restore --list "${remote_dump_path}" > "${restore_list_file}"
head -20 "${restore_list_file}"
rm -f "${restore_list_file}"

if [ "${REPLACE_EXISTING}" = "--replace-existing" ]; then
  echo "==> --replace-existing: dropping and recreating ${DB_NAME} before restore"
  kubectl -n "${NAMESPACE}" exec "${POD}" -- \
    psql -U "${DB_USER}" -d postgres -c "DROP DATABASE IF EXISTS ${DB_NAME};"
  kubectl -n "${NAMESPACE}" exec "${POD}" -- \
    psql -U "${DB_USER}" -d postgres -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};"
else
  echo "==> ensuring target database '${DB_NAME}' exists"
  kubectl -n "${NAMESPACE}" exec "${POD}" -- \
    psql -U "${DB_USER}" -d postgres -tAc \
    "SELECT 1 FROM pg_database WHERE datname = '${DB_NAME}'" | grep -q 1 || \
    kubectl -n "${NAMESPACE}" exec "${POD}" -- \
      createdb -U "${DB_USER}" -O "${DB_USER}" "${DB_NAME}"
fi

echo "==> restoring into ${NAMESPACE}/${DB_NAME}"
restore_status=0
kubectl -n "${NAMESPACE}" exec "${POD}" -- \
  pg_restore --no-owner --no-privileges -U "${DB_USER}" -d "${DB_NAME}" "${remote_dump_path}" || restore_status=$?

if [ "${restore_status}" -ne 0 ]; then
  echo "error: pg_restore exited ${restore_status}" >&2
  exit "${restore_status}"
fi

echo
echo "Restore complete into ${NAMESPACE}/${DB_NAME}."
