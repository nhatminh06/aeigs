#!/usr/bin/env bash
# Creates an encrypted, off-host logical backup of the stateful-lab
# PostgreSQL instance on home-k3s. Run from the operator's own machine —
# never from the K3s host itself, and never writes anything to that
# host's disk or its PVC.
#
# pg_dump runs INSIDE the postgresql-0 container (kubectl exec), so the
# dump always matches the exact running PostgreSQL version with no local
# client dependency. It connects over the container's local Unix socket,
# which this Deployment's default pg_hba.conf trusts without a password —
# nothing here ever touches the database credential.
#
# See docs/runbooks/stateful-lab-postgresql-backup-restore.md.
#
# AEGIS_HOME_K3S_CONTEXT: same purpose as in
# scripts/bootstrap-cilium-home-k3s.sh — lets this script safely target a
# replacement-host reconstruction test. Unset, behavior is unchanged.
set -euo pipefail
umask 077

EXPECTED_CONTEXT="${AEGIS_HOME_K3S_CONTEXT:-home-k3s}"
NAMESPACE="stateful-lab"
POD="postgresql-0"
DB_USER="aegis"
DB_NAME="aegis_state"
BACKUP_KEY_FILE="${AEGIS_BACKUP_AGE_KEY_FILE:-${HOME}/.config/aegis/backup/age/keys.txt}"
BACKUP_ROOT="${AEGIS_BACKUP_DIR:-${HOME}/.local/share/aegis/backups/stateful-lab/postgresql}"

for cmd in kubectl age age-keygen sha256sum; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "error: required command '${cmd}' not found on PATH" >&2
    exit 1
  fi
done

current_context="$(kubectl config current-context 2>/dev/null || true)"
if [ "${current_context}" != "${EXPECTED_CONTEXT}" ]; then
  echo "error: kubectl context is '${current_context}', expected '${EXPECTED_CONTEXT}'" >&2
  echo "       refusing to back up a database on the wrong cluster" >&2
  exit 1
fi

if [ ! -f "${BACKUP_KEY_FILE}" ]; then
  echo "error: backup age key not found at '${BACKUP_KEY_FILE}'" >&2
  exit 1
fi
backup_recipient="$(age-keygen -y "${BACKUP_KEY_FILE}" 2>/dev/null || true)"
if [ -z "${backup_recipient}" ]; then
  echo "error: could not derive a public key from '${BACKUP_KEY_FILE}'" >&2
  exit 1
fi

pod_ready="$(kubectl -n "${NAMESPACE}" get pod "${POD}" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true)"
if [ "${pod_ready}" != "true" ]; then
  echo "error: ${NAMESPACE}/${POD} is not Ready" >&2
  exit 1
fi

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
dest_dir="${BACKUP_ROOT}/${timestamp}"
mkdir -p "${dest_dir}"

plaintext_dump="$(mktemp)"
cleanup() {
  rm -f "${plaintext_dump}"
}
trap cleanup EXIT

echo "==> pre-backup data fingerprint"
fingerprint="$(kubectl -n "${NAMESPACE}" exec "${POD}" -- \
  psql -U "${DB_USER}" -d "${DB_NAME}" -t -A -F',' \
  -c "SELECT id, value FROM persistence_proof ORDER BY id;" \
  | sha256sum | cut -d' ' -f1)"
echo "    ${fingerprint}"

pg_version="$(kubectl -n "${NAMESPACE}" exec "${POD}" -- \
  psql -U "${DB_USER}" -d "${DB_NAME}" -t -A -c "SHOW server_version;")"

echo "==> pg_dump (custom format) -> local temp file"
start_time="$(date -u +%FT%TZ)"
kubectl -n "${NAMESPACE}" exec "${POD}" -- \
  pg_dump -U "${DB_USER}" -Fc -d "${DB_NAME}" > "${plaintext_dump}"
end_time="$(date -u +%FT%TZ)"

plaintext_sha256="$(sha256sum "${plaintext_dump}" | cut -d' ' -f1)"
plaintext_size="$(wc -c < "${plaintext_dump}" | tr -d ' ')"

git_revision="$(git -C "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" rev-parse HEAD 2>/dev/null || echo unknown)"

pvc_uid="$(kubectl -n "${NAMESPACE}" get pvc data-postgresql-0 -o jsonpath='{.metadata.uid}' 2>/dev/null || echo unknown)"
pv_name="$(kubectl -n "${NAMESPACE}" get pvc data-postgresql-0 -o jsonpath='{.spec.volumeName}' 2>/dev/null || echo unknown)"
pv_uid="$(kubectl get pv "${pv_name}" -o jsonpath='{.metadata.uid}' 2>/dev/null || echo unknown)"

artifact="${dest_dir}/stateful-lab-postgresql-${timestamp}.dump.age"
echo "==> encrypting to ${artifact}"
age -r "${backup_recipient}" -o "${artifact}" "${plaintext_dump}"
encrypted_sha256="$(sha256sum "${artifact}" | cut -d' ' -f1)"
encrypted_size="$(wc -c < "${artifact}" | tr -d ' ')"

rm -f "${plaintext_dump}"
trap - EXIT

metadata="${dest_dir}/stateful-lab-postgresql-${timestamp}.metadata.txt"
cat > "${metadata}" <<EOF
backup_timestamp: ${timestamp}
backup_start: ${start_time}
backup_end: ${end_time}
source: home-k3s
namespace: ${NAMESPACE}
database: ${DB_NAME}
postgresql_version: ${pg_version}
format: pg_dump custom (-Fc), age-encrypted
plaintext_sha256: ${plaintext_sha256}
plaintext_size_bytes: ${plaintext_size}
encrypted_artifact: $(basename "${artifact}")
encrypted_sha256: ${encrypted_sha256}
encrypted_size_bytes: ${encrypted_size}
pre_backup_fingerprint_sha256: ${fingerprint}
git_revision: ${git_revision}
pvc_name: data-postgresql-0
pvc_uid: ${pvc_uid}
pv_name: ${pv_name}
pv_uid: ${pv_uid}
backup_key_recipient: ${backup_recipient}
EOF

echo
echo "Backup complete."
echo "  artifact:  ${artifact}"
echo "  metadata:  ${metadata}"
echo "  encrypted sha256: ${encrypted_sha256}"
echo
echo "This backup and ${BACKUP_KEY_FILE} are BOTH required to restore it."
echo "Neither is backed up anywhere else yet — see the runbook's limitations section."
