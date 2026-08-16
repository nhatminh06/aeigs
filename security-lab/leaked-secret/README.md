# Lab: leaked secret

## Objective

Confirm the repository's secret-scanning control actually detects a
committed credential, rather than assuming it works because the CI job
exists.

## Threat

A private key, token, or password committed to Git is exposed to everyone
with read access — and stays in history after the file is deleted. This
repository is public, so a leak is immediately public. Rotation is the
only real remedy, which makes detection *before* the push the control
that matters.

## Control

Gitleaks, run in CI on every push and pull request
(`.github/workflows/repo-security.yml`), scanning full history with
`--exit-code 1` so a finding fails the build.

## Test procedure

```
./security-lab/leaked-secret/test.sh
```

The script builds its fixture at runtime in a `mktemp -d` directory: an
RSA private key block whose body is `openssl rand -base64 48`. Nothing
credential-shaped is ever written into the repository, and the fixture is
removed by a `trap ... EXIT` cleanup.

The credential markers in the script are assembled from split string
fragments (`'-----BEGIN'` + `' RSA PRIVATE KEY-----'`). Writing a complete
marker literally would make Gitleaks flag this lab's own source — the
scanner does not care that a secret is fake.

Gitleaks exits non-zero when it finds something, so the lab inverts that:
a *clean* scan of a deliberately-planted secret is the failure case.

## Expected result

Gitleaks reports one finding under rule `private-key`, and the lab exits 0.

## Observed result

Run on 2026-08-16, gitleaks 8.30.1:

```
==> planted a synthetic credential in /var/folders/.../tmp.QR5mfrqnni
PASS: Gitleaks detected the planted credential (rule: private-key)
```

The control was also tested in the failing direction: with a stub
`gitleaks` on `PATH` that always exits 0, the lab reported
`FAIL: Gitleaks scanned the fixture and reported no leak` and exited 1.
That confirms the lab measures the scanner's behaviour rather than only
its own logic.

Scanning the repository itself after adding this lab still reports
`no leaks found`, confirming the split-fragment construction works.

## Limitation

This exercises the `private-key` rule against a file on disk. It does not
prove Gitleaks catches every credential format, and it does not test the
history-scanning path — CI scans full history, while the lab scans a
temporary directory with `--no-git`. It also cannot prove a secret never
reached the remote: Gitleaks is a pre-merge control, not a guarantee
about what already happened.
