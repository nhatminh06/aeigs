# Runbook: dependency upgrade validation

Use this before merging a dependency upgrade. The objective is to show that
the candidate still satisfies the controls and behavior AEIGS relies on, not
merely that a version string changed cleanly.

Renovate opens proposals but never automerges them. A merged manifest change
is desired state and Flux may apply it without another approval step, so do
the preparation and static checks before merge and the runtime checks as soon
as the change reaches each affected environment.

## Classify by risk, not only by version shape

These are AEIGS operational categories; they do not assume every upstream
project follows strict SemVer.

| Class | Example | Minimum handling |
|---|---|---|
| Patch | `2.9.4` → `2.9.5` | CI plus relevant runtime smoke validation |
| Minor | `3.8.x` → `3.9.x` | Release-note review, CI, and component-specific runtime validation |
| Major | `88.x` → `91.x` | Dedicated PR, migration and breaking-change review, rollback plan, CI, component-specific validation, and recorded evidence |

Risk overrides the number. A patch to Authentik, PostgreSQL, an admission
controller, or another stateful/security-sensitive component can require more
evidence than a major update to a development-only tool. Do not bundle a major
upgrade with unrelated dependency changes.

## Standard workflow

```text
Renovate PR -> release notes -> risk classification -> affected environments
-> rollback/recovery preparation -> repository CI -> merge -> Flux reconcile
-> runtime health -> component/security/observability checks -> evidence
```

### Before merge

- [ ] Read upstream release notes for every version crossed.
- [ ] Identify breaking, deprecated, migration, configuration, and CRD/schema
      changes. Check project-specific versioning policy rather than assuming
      SemVer behavior.
- [ ] Identify every affected AEIGS component and environment. Shared bases
      can affect both `dev-kind` and `home-k3s`.
- [ ] Decide whether persistent data, identity, trust, admission, networking,
      or the GitOps control plane is in the failure path.
- [ ] Confirm the current environment is healthy so pre-existing failures are
      not attributed to the upgrade.
- [ ] Define the known-good version and the Git change needed to restore it.
- [ ] For important persistent state, confirm a successful backup and a known
      restore path. Stateless changes do not need ceremonial backups.
- [ ] Confirm all required PR checks pass.

Record pre-change values when they are needed to prove preservation: deployed
version/image, Flux revision, identity UUID, PVC/PV identity, certificate
state, policy result, or a relevant application-level result.

### Repository and static validation

Run `./scripts/verify-repo.sh` for the canonical local implementation of the
static checks below. CI invokes the same script stages while retaining
separate jobs and checksum-verified tool installation. Trivy is the explicit
exception when no local binary is installed: the verifier reports it skipped,
and the pinned CI Trivy action remains required.

The `repo-security` workflow currently enforces:

- Gitleaks committed-secret scanning;
- Trivy Kubernetes configuration scanning;
- Kyverno fixture tests;
- Kustomize rendering of `clusters/dev-kind` and `clusters/home-k3s`;
- kubeconform validation of the rendered built-in and Flux resources, with
  the workflow's explicit CRD-definition limitation;
- ShellCheck over `scripts/*.sh`; and
- Renovate configuration validation.

Inspect the PR checks rather than reproducing selected green results by hand.
If the workflow itself changes, run its documented commands locally where
practical. Kustomize rendering proves composition; kubeconform proves the
covered schemas; neither is a live Kubernetes API-server admission test.
Kyverno's CI fixtures test rule logic but not every live admission operation.

Passing CI is necessary, not runtime evidence. **Configuration is not
evidence.**

## Apply and minimum runtime validation

After merge, allow Flux to observe the intended Git revision. Use the correct
kubeconfig/context, then inspect rather than hand-patching desired state:

```sh
flux get sources git
flux get kustomizations
flux get helmreleases -A
kubectl get nodes
kubectl get pods -A
```

- [ ] Git sources and affected Kustomizations/HelmReleases are `Ready` at the
      expected revision.
- [ ] Expected nodes and workloads settle to `Ready`.
- [ ] No unexpected `CrashLoopBackOff` or `ImagePullBackOff` remains.
- [ ] Affected controllers are healthy and expected Services/endpoints exist.
- [ ] Component behavior—not only pod health—passes the relevant checks below.

A transient rollout is not automatically a failure; use events and logs to
distinguish progress from a stuck migration or crash loop. A green pod alone
does not prove application correctness.

## Component-specific checks

Run only the sections touched by the upgrade, plus checks for dependencies in
its failure path.

### Flux

- Confirm the Git source reaches the expected revision and all affected
  Kustomizations/HelmReleases become `Ready`.
- Confirm Flux controllers are healthy and an expected reconciliation occurs.
- For control-plane or CRD changes, check controller events/logs for conversion
  or API errors; do not infer compatibility from controller pods alone.
- Keep the Flux schema version/checksum in `repo-security` aligned with the
  Flux release being validated; otherwise kubeconform may check custom
  resources against the previous release's schema.
- Use the health sequence in
  [`home-k3s-recovery.md`](home-k3s-recovery.md) for the persistent cluster.

### Kyverno and admission policy

- Confirm Kyverno and policy resources are ready.
- Require the CI fixture suite, then choose relevant live checks from
  [`security/policies/tests/README.md`](../../security/policies/tests/README.md):
  pinned images accepted, `latest`/untagged images rejected, and privileged
  workloads rejected.
- For image-verification changes, run
  `./security-lab/unsigned-image/test.sh`: the current trusted signed digest
  must be accepted and the documented unsigned candidates rejected.
- The wrong-signer case is historical evidence, not an automated routine test;
  do not claim it was rerun unless a suitable untrusted signature exists and
  the manual procedure was actually performed.

Static `kyverno test` success does not replace live webhook behavior. The
policy test documentation records bugs that only appeared during live
CREATE/UPDATE/DELETE behavior.

### Authentik

Treat Authentik upgrades as stateful and identity-sensitive regardless of
version size.

- [ ] Server, worker, and PostgreSQL are healthy after any migrations finish.
- [ ] The existing DB-only test identity is present and, where comparison is
      required, retains its UUID/active/non-admin state.
- [ ] Authentik's health endpoint succeeds through trusted HTTPS.
- [ ] A fresh OIDC login succeeds and Grafana accepts the authentication.
- [ ] `scripts/backup-status.sh` is healthy; for a significant change, run the
      Authentik backup/restore verification appropriate to the risk.

Use [`home-k3s-authentik.md`](home-k3s-authentik.md) for exact health, identity,
OIDC, backup, and restore procedures. Git reconstructs objects; it does not
restore identity rows.

### Prometheus and Grafana

- [ ] Prometheus, Grafana, the operator, exporters, and kube-state-metrics are
      healthy.
- [ ] Expected scrape targets—especially `aegis-api`—are `up`.
- [ ] `aegis-api.rules` and `aegis-api.alerts` are loaded and healthy.
- [ ] Grafana health succeeds and the expected dashboard/data is available.

Follow [`home-k3s-observability.md`](home-k3s-observability.md) for the exact
API checks. For an application SLO regression, use
[`aegis-api-bad-release.md`](aegis-api-bad-release.md); do not invent a new
threshold in this runbook.

### cert-manager and TLS

- [ ] cert-manager controllers are healthy.
- [ ] affected Issuers and Certificates report `Ready`.
- [ ] an existing endpoint succeeds with the Aegis development CA, not only
      with TLS verification disabled.

The home environment's commands and nginx certificate-reload limitation are
in [`home-k3s-ingress-recovery.md`](home-k3s-ingress-recovery.md) and
[`home-k3s-nginx-cert-reload.md`](home-k3s-nginx-cert-reload.md).

### Cilium and networking

- [ ] Cilium agents, Envoy, and operator are healthy; `cilium-dbg status
      --brief` reports `OK` when run as documented in
      [`home-k3s-recovery.md`](home-k3s-recovery.md).
- [ ] DNS and expected application connectivity still work.
- [ ] Intended isolation still works. For Authentik paths, run
      `./security-lab/network-lateral-movement/test.sh` and confirm legitimate
      application flows separately as documented by that lab.

Do not use the Cilium Gateway path as a home-k3s success criterion. The
documented `reserved:ingress` datapath defect remains; home-k3s uses its
Flux-owned nginx ingress. Re-run `ingress-lab/` before claiming a future Cilium
version fixes that path.

## Stateful upgrades and rollback

Before changing a component with important persistent state:

- [ ] A relevant backup completed successfully.
- [ ] Integrity/restore verification is current enough for the risk.
- [ ] The restore procedure and required keys are available.
- [ ] Rollback implications are understood, including whether a migration is
      backward-compatible with the old binary/chart.

A file's existence is not proof of recoverability. A backup provides stronger
evidence when its restore path has been tested. Use
[`stateful-lab-postgresql-backup-restore.md`](stateful-lab-postgresql-backup-restore.md)
and [`home-k3s-authentik.md`](home-k3s-authentik.md), including their documented
single-destination/key-redundancy limitations. K3s binary changes have a
separate SQLite and application-data procedure in
[`home-k3s-upgrade.md`](home-k3s-upgrade.md).

Roll back through Git when any of these persists or violates the candidate's
acceptance criteria:

- Flux or an affected controller cannot reconcile;
- workloads do not become ready or repeatedly crash;
- identity, OIDC, or integrated authentication breaks;
- admission behavior changes unexpectedly;
- connectivity or NetworkPolicy isolation regresses;
- scrape targets, rules, dashboards, or other required monitoring disappear;
- the documented application SLO/objective regresses; or
- persistent state changes unexpectedly or a migration cannot be verified.

Rollback is an expected engineering response to contrary evidence. Revert to
the recorded known-good Git state, reconcile, repeat the same runtime checks,
and record the outcome. If a data migration prevents safe binary rollback,
stop and use the prepared upstream recovery/restore plan rather than guessing.

## Merge expectations and evidence

| Upgrade | Merge expectation |
|---|---|
| Patch | Green CI plus relevant runtime smoke validation |
| Minor | Release-note review, green CI, and component-specific runtime validation |
| Major | Dedicated PR, migration/breaking-change review, rollback plan, green CI, component-specific validation, and documented evidence |

For significant, stateful, or security-sensitive upgrades, record the
dependency, old/new versions, date, affected environments, release notes
reviewed, CI result, runtime and security/functionality checks, backup/restore
status where applicable, problems, whether rollback occurred, and final
outcome. A PR description or existing evidence/runbook is normally enough;
do not create a new file for every routine patch.

## Backlog sanity check

Apply the policy consistently:

- Flux `2.9.4` → `2.9.5`: patch handling, but validate reconciliation because
  it is the GitOps control plane.
- Kyverno chart `3.8.2` → `3.9.1`: minor handling plus static and live admission
  checks because policy enforcement is security-sensitive.
- kube-prometheus-stack `88.5.0` → `88.6.5`: minor handling; review chart
  notes and validate targets, rules, Grafana, and both affected environments.
- A cert-manager patch: patch handling plus controller, Certificate, and
  trusted-endpoint validation.
- An Authentik patch: stronger stateful/identity workflow despite patch size.
- A kube-prometheus-stack `88.x` → `91.x` change: major, dedicated PR with
  breaking/migration review, rollback plan, component checks, and evidence.

These examples classify the work; they do not approve or perform any upgrade.
