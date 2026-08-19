# Portfolio materials

Supporting copy for résumés, interviews, and a portfolio site. Every
number here is traced to a real experiment documented elsewhere in this
repository — see the linked evidence, not this file, as the source of
truth.

## 60-second pitch

Aegis is a self-hosted GitOps Kubernetes platform I built to answer one
question: not "can I deploy this stack," but "what actually happens when
each layer fails." It runs two environments — a disposable local cluster
for experimentation and a persistent home server for host-lifecycle
proof — with one owned Go application carrying a full signed-release
pipeline: Trivy scan, SBOM, Cosign keyless signature, Kyverno admission.

The strongest proof isn't that the controls exist — it's that I broke
them on purpose and watched what happened. A signed, fully-admitted
release with a real latency regression got auto-deployed and was caught
only by Prometheus, not by any security control, in about two minutes. I
destroyed a PostgreSQL volume backing a Kubernetes-native identity
provider and proved Git alone couldn't rebuild the missing user — only an
encrypted, verified backup could, and the restored identity kept its
original UUID and could still log in. And when I tried to reuse
identical Kubernetes networking architecture across environments, real
packet-level evidence disagreed with the plan, so I changed the
architecture instead of forcing it to match.

## 5-minute technical explanation

**1. Goal.** Prove Kubernetes controls under real failure, not just
configure them. Everything in the repo maps to a specific proven claim.

**2. dev-kind.** Disposable `kind` cluster, Cilium CNI + Gateway API,
Flux with full image automation — a new signed aegis-api release is
discovered, selected, and committed to Git automatically, with Kyverno's
signature check as an independent gate `ImagePolicy` cannot bypass. This
is where the security and reliability labs live: leaked-credential
detection, unsigned/wrong-signer image denial, lateral-movement
blocking, and the signed-but-bad-release SLO experiment.

**3. home-k3s.** Persistent K3s on a real Linux host. No image
automation — release promotion is a deliberate human Git commit, by
design, to keep the persistent environment's blast radius small. This is
where every destructive-recovery experiment lives: Pod loss, host
reboot, PVC/PV destruction and restore, full replacement-host
reconstruction, and a real K3s version rollback.

**4. Supply chain.** Three independent layers, proven separately:
`ImagePolicy` selects a version, Kyverno decides if it's *trusted*
(signature identity, not just presence), Prometheus decides if a trusted
release actually *works*. No layer defers trust to the one before it —
proven by feeding `ImagePolicy` a real unsigned digest and watching
Kyverno deny it anyway.

**5. Security boundaries.** SOPS+age for every secret, Cilium +
NetworkPolicy for lateral movement (proven with a real before/after
Hubble capture), cert-manager TLS from a shared development CA, Authentik
OIDC for identity in both environments.

**6. Failure and recovery.** The strongest section. A signed release with
a real bug, caught by SLOs, not admission control. A destroyed database
identity, recovered from an encrypted off-host backup with the exact
same UUID. A Kubernetes networking assumption that turned out to be
wrong on real hardware, disproven with packet captures, and the
architecture changed as a result.

**7. Lesson.** Configuration is a claim. A test against real failure is
evidence. Aegis is built around making every claim it makes falsifiable
and, where possible, already falsified and fixed once.

## Interview stories

### A. The Cilium Gateway datapath failure

- **Situation**: home-k3s was meant to reuse dev-kind's Cilium Gateway
  API for ingress — same CNI, same version.
- **Problem**: every request through the Gateway returned 503. No
  NetworkPolicy, firewall rule, or config change fixed it.
- **Action**: captured live packet traces with `cilium-dbg monitor
  --type trace`, found connections tagged with Cilium's
  `reserved:ingress` identity got a SYN-ACK back but never completed the
  handshake. Built a control experiment (a plain nginx proxy, pod-to-pod
  then via NodePort) to isolate whether this was Gateway-specific or a
  general host networking problem.
- **Evidence**: the control path succeeded 20/20 on every request, both
  legs, full clean handshakes every time; the Gateway path failed 100%
  of requests with the identical symptom reproduced on two Cilium
  versions.
- **Lesson**: don't force an architecture to match a plan when live
  evidence disagrees — home-k3s now runs nginx by design, documented as
  an ADR, not silently patched around.

### B. The ignored Helm value that defeated a NetworkPolicy

- **Situation**: wrote a restrictive NetworkPolicy to block lateral
  movement to Authentik's PostgreSQL.
- **Problem**: the policy existed, was applied, and still didn't block
  traffic in testing.
- **Action**: traced it to the bundled Bitnami PostgreSQL subchart
  shipping its own permissive NetworkPolicy (open from `<any>` source) —
  NetworkPolicies are additive, so the permissive one silently canceled
  the restrictive one.
- **Evidence**: Hubble showed `INGRESS ALLOWED` before disabling the
  subchart's own policy (`postgresql.primary.networkPolicy.enabled:
  false`), `INGRESS DENIED / DROPPED` after.
- **Lesson**: a chart's default values are part of your security
  posture whether you read them or not — verify the actual applied
  policy, not just the one you wrote.

### C. The signed-but-bad release

- **Situation**: Flux Image Automation auto-deploys any signed release
  that passes the full supply chain.
- **Problem**: proving that "signed and admitted" doesn't mean
  "correct."
- **Action**: shipped a real algorithmic regression (recursive instead
  of iterative Fibonacci) through the complete pipeline — tests, Trivy,
  SBOM, Cosign, Kyverno — deliberately, then watched what actually
  caught it.
- **Evidence**: p95 latency went from a 4.75ms baseline to 237ms against
  a 100ms objective, detected in about two minutes by Prometheus alone
  — Kubernetes, Kyverno, and Hubble all reported the workload healthy
  throughout. Recovery was one Git commit, ~3 minutes to firing→commit,
  ~22 seconds rollout.
- **Lesson**: security admission and application correctness are
  different failure domains that need different detection mechanisms —
  neither substitutes for the other.

### D. Authentik destructive identity recovery

- **Situation**: needed to prove Git-based GitOps recovery and
  database-backed identity recovery are genuinely different things, not
  just claim it.
- **Problem**: designing a test where Git reconstruction *could* look
  like it recovered identity, if not carefully separated.
- **Action**: created a test user directly through Authentik's API,
  deliberately never declared in any Git-managed blueprint, then
  destroyed the PVC/PV backing its PostgreSQL and confirmed — before
  touching any backup — that the user was genuinely absent after Flux
  and Django's own migrations rebuilt everything else.
- **Evidence**: restored from an encrypted off-host backup, the same
  UUID returned, a real interactive OAuth login succeeded, and it
  survived a full host reboot performed afterward.
- **Lesson**: "GitOps recovers everything" is a claim that needs a
  negative-space test — proving what *doesn't* come back from Git is as
  important as proving what does.

### E. Flux credential hardening

- **Situation**: the token used to bootstrap Flux (write access via the
  GitHub API) defaults to also becoming the ongoing runtime credential
  Flux uses for every subsequent Git fetch.
- **Problem**: this repository is public and read-only for Flux's core
  reconciliation — an indefinitely-held write-capable token was
  unnecessary exposure.
- **Action**: removed the `GitRepository`'s `secretRef` entirely after
  bootstrap and verified anonymous HTTPS reconciliation still works;
  later, when Image Automation needed genuine write access, gave it its
  own dedicated, path-scoped, fine-grained PAT instead of reusing or
  widening the original one.
- **Evidence**: live-verified reconciliation with no credential present;
  a separate ADR (0012) records the scoped-credential design for the one
  place a write credential is actually needed.
- **Lesson**: a bootstrap credential and a runtime credential are
  different concerns with different lifetimes — don't let the
  convenience of "it already has a token" become a lingering privilege.

## Resume bullets

**A. DevOps / Platform Engineering**
- Built and operated a two-environment GitOps Kubernetes platform (Flux, Kyverno, Cilium) with a full signed-release supply chain (Trivy → SBOM → Cosign → admission) and automated image promotion gated independently by policy.
- Proved destructive-recovery claims live, not just documented: PVC/PV destruction and restore, full replacement-host reconstruction, and a real K3s version rollback, each with exact before/after data fingerprints.
- Designed and scheduled an encrypted, verified PostgreSQL backup system (age encryption, checksum + scratch-restore verification, launchd scheduling) covering two independent database families.

**B. DevSecOps / Security Engineering**
- Implemented and live-tested a Kubernetes admission supply chain (Cosign keyless signing + Kyverno `verifyImages`) that denies both unsigned and wrong-signer images with distinct, auditable error messages.
- Ran deliberate attack experiments (leaked credential, lateral network movement, unsigned image) against real controls, each with before/after evidence via Gitleaks and Cilium/Hubble packet-verdict capture, not policy inspection alone.
- Proved destructive identity recovery for an OIDC provider's own database: confirmed identity absence post-Git-reconstruction, then restored the exact UUID from an encrypted off-host backup with a real OAuth login proof.

**C. Systems / Infrastructure Engineering**
- Diagnosed a Cilium Gateway API datapath defect down to the TCP handshake level using live eBPF-based packet tracing (`cilium-dbg`), isolated it with a controlled experiment (20/20 reproducible pass/fail split), and re-architected ingress around the evidence.
- Operated a persistent single-node K3s host through service restarts, a full reboot, and a real K3s binary version change/rollback, verifying application, identity, networking, and TLS state at every step.
- Built a Prometheus SLO pipeline that caught a real latency regression in a fully signed, policy-admitted release within ~2 minutes, when every security/orchestration signal reported the workload healthy.

## Website copy

**One-line summary**: A self-hosted GitOps Kubernetes platform built to
prove security and reliability controls under real, deliberate failure —
not just to configure them.

**50-word summary**: Aegis runs two Kubernetes environments — disposable
and persistent — with a full signed-release supply chain, GitOps-managed
secrets and identity, and a library of deliberate failure experiments:
leaked credentials, unsigned images, lateral network movement, a
signed-but-broken release, database destruction, and a real host reboot,
each proven with live evidence.

**150-word description**: Aegis is a security-focused GitOps platform
spanning two Kubernetes environments: a disposable local cluster for
experimentation and a persistent home server for proving host-lifecycle
recovery. Every component — Flux, Kyverno, Cilium, cert-manager,
Authentik, Prometheus — is wired together around one owned Go
application with a complete signed-release pipeline (Trivy scan, SBOM
attestation, Cosign keyless signing, independent Kyverno admission).

What sets the project apart is its evidence discipline: every major
claim is backed by a deliberate failure experiment with real command
output, not just working configuration. A signed, fully-admitted release
with a genuine latency regression was caught only by Prometheus SLOs,
not by any security control. A PostgreSQL volume backing an identity
provider was destroyed on purpose to prove Git alone can't rebuild
missing data — only an encrypted, verified backup can. When two
environments' identical network architecture disagreed with live packet
evidence, the architecture changed, not the evidence.

**Key lesson**: Configuration is a claim; a test against real failure is
evidence.

**GitHub CTA**: See the full platform, evidence, and recovery
experiments: [github.com/nhatminh06/aeigs](https://github.com/nhatminh06/aeigs)
