# Final architecture diagram — specification

This is a **textual specification** for a future 1:1 replacement of
`docs/architecture/architecture.png`, which is known stale (predates
Cilium/Hubble, Authentik, aegis-api, home-k3s entirely — see the note in
the README). `architecture.png` itself is not touched by this
specification; `docs/architecture/README.md` remains the accurate,
current text/ASCII description until an actual image is produced.

## Layout

```
TOP
  GitHub (github.com/nhatminh06/aeigs)  --  GHCR (ghcr.io/nhatminh06/aegis-api)

LEFT                                    RIGHT
  dev-kind                                home-k3s
  (disposable, kind on a laptop)          (persistent, K3s on a real Linux host)

CENTER (between the two, shared concepts, drawn once — NOT a shared
  control plane, both environments read Git independently)
  Flux
  Kyverno
  SOPS + age
  supply chain (Trivy / SBOM / Cosign)

BOTTOM
  security & recovery evidence layer
```

## What belongs in each region

**TOP**: two boxes — GitHub (source of both the platform repo and
`aegis-api`'s own repo) and GHCR (where signed `aegis-api` images land).
An arrow from GitHub's `aegis-api` repo through a small CI pipeline
(tests → Trivy → SBOM → Cosign) into GHCR. A separate arrow from GitHub's
platform repo down into both `dev-kind` and `home-k3s`'s Flux — drawn as
**two independent arrows**, not one arrow that forks inside Kubernetes,
since there is no shared control plane.

**LEFT (dev-kind)**: Cilium (CNI + Gateway API + Hubble), cert-manager,
Grafana, Authentik (bundled/ephemeral Postgres), Prometheus, aegis-api,
Flux Image Automation (`ImageRepository`/`ImagePolicy`/`ImageUpdateAutomation`
— draw this as a loop feeding back into the GitHub arrow, since it writes
commits). Label the ingress path explicitly as **Cilium Gateway API**.

**RIGHT (home-k3s)**: Cilium (CNI + kube-proxy replacement, Gateway CRDs
installed but explicitly labeled "installed, not used"), nginx (labeled
as the **active** ingress mechanism, NodePort), cert-manager, Grafana,
Prometheus, Authentik (own standalone persistent Postgres), aegis-api
(manually promoted — no automation boxes here), stateful-lab PostgreSQL,
and an explicit arrow labeled "encrypted backup" running from both
PostgreSQL instances off the diagram toward a small "Mac (operator
workstation)" box at the very bottom-right — this is the one place the
two environments' diagrams should visually diverge in ingress mechanism,
and it should be impossible to mistake which side uses which.

**CENTER**: draw Flux, Kyverno, SOPS+age, and the supply-chain concept
as small shared-pattern icons positioned between the two environment
columns, with a note: "same pattern, independently deployed in each
environment — not a shared instance." This avoids the most likely
misreading of a side-by-side diagram (that Kubernetes state is shared).

**BOTTOM**: a thin evidence-layer strip listing, as small labeled marks
under the relevant boxes rather than a separate legend: Gitleaks (CI),
security-lab attack scenarios (under dev-kind), reliability-lab SLO
experiment (under dev-kind's aegis-api), ingress-lab control experiment
(under home-k3s's ingress boundary), destructive-recovery proofs (under
home-k3s's PostgreSQL boxes). This is what makes the diagram distinct
from a generic "tools I used" architecture diagram — it visually ties
each major box to the experiment that tested it.

## Explicit divergence to show, not hide

- Ingress: Cilium Gateway (dev-kind) vs. nginx NodePort (home-k3s) —
  label both, and add a one-line caption near home-k3s's ingress box:
  "Cilium Gateway installed but unused — reserved:ingress datapath
  defect, see ADR 0014."
- Release promotion: automated (dev-kind, loop back into GitHub) vs.
  manual (home-k3s, no loop, just a static "human commits digest" label).
- Authentik PostgreSQL: bundled/ephemeral (dev-kind) vs. standalone/
  persistent with its own backup arrow (home-k3s).

## What NOT to show

- No shared Kubernetes control plane or shared node pool between the two
  columns — they are visually separate clusters end to end.
- No implication that home-k3s has image automation, a Git write
  credential, or an `ImagePolicy`/`ImageRepository` — home-k3s's Flux box
  should visibly have fewer components than dev-kind's.
- No claim of HA, load balancing, or multi-node anywhere in either
  column — both are single-cluster, and home-k3s is explicitly
  single-node.

## Format

No format constraint from this spec — draw.io, Excalidraw, or a
hand-built SVG are all fine. Whatever tool is used, export a static PNG
to replace `docs/architecture/architecture.png` and keep this spec
committed alongside it as the source-of-intent document, since the tool's
native source file (if any) likely won't be checked in either.
