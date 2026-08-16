#!/usr/bin/env bash
# Proves the Gitleaks control actually detects a committed credential,
# rather than assuming it does because the CI job exists.
#
# The fixture is built at runtime in a temporary directory and never
# written into the repository. The credential markers below are assembled
# from split fragments on purpose: a complete marker written literally in
# this file would make Gitleaks flag this script itself, which is exactly
# the failure mode the lab is meant to demonstrate elsewhere.
#
# Exits 0 only if Gitleaks reported the planted secret.
set -euo pipefail

if ! command -v gitleaks >/dev/null 2>&1; then
  echo "error: required command 'gitleaks' not found on PATH" >&2
  exit 1
fi
if ! command -v openssl >/dev/null 2>&1; then
  echo "error: required command 'openssl' not found on PATH" >&2
  exit 1
fi

WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "${WORKDIR}"; }
trap cleanup EXIT

# Random body, so nothing here is a real key and no fixed secret value
# ever exists on disk twice.
{
  printf -- '-----BEGIN'; printf ' RSA PRIVATE KEY-----\n'
  openssl rand -base64 48
  printf -- '-----END'; printf ' RSA PRIVATE KEY-----\n'
} > "${WORKDIR}/deploy-key.pem"

echo "==> planted a synthetic credential in ${WORKDIR}"

# gitleaks exits non-zero when it finds something, which is the success
# case here, so the exit code is inverted deliberately.
if gitleaks detect --source "${WORKDIR}" --no-git --redact -v --no-color \
     --exit-code 1 > "${WORKDIR}/scan.log" 2>&1; then
  echo "FAIL: Gitleaks scanned the fixture and reported no leak" >&2
  echo "      the secret-scanning control did not catch a planted credential" >&2
  exit 1
fi

if ! grep -q 'RuleID:.*private-key' "${WORKDIR}/scan.log"; then
  echo "FAIL: Gitleaks exited non-zero but not via the private-key rule" >&2
  sed -n '1,20p' "${WORKDIR}/scan.log" >&2
  exit 1
fi

echo "PASS: Gitleaks detected the planted credential (rule: private-key)"
