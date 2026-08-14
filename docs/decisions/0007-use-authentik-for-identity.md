# 7. Use Authentik for identity, configured declaratively via blueprints

## Status

Accepted

## Context

Per `CLAUDE.md`, Authentik is only introduced once an application actually
benefits from centralized auth, and its configuration must live in Git
like everything else — manual UI clicks inside Authentik would make it
the one part of the platform not managed by GitOps. Grafana (admin/local
password only, from PR 6) is the first real candidate.

## Decision

Deploy Authentik via `HelmRelease` (`security/authentik/`, chart pinned
`2026.5.6`), with an in-cluster, non-persistent Postgres (Authentik no
longer depends on Redis as of this chart version). Configure the OIDC
provider and application for Grafana declaratively through an Authentik
**blueprint** — a YAML file describing desired Authentik objects,
mounted into the pod from a SOPS-encrypted `Secret`
(`security/authentik/blueprint.enc.yaml`) via the chart's
`blueprints.secrets` mechanism — instead of the Authentik admin UI.

All credentials (Authentik's `secret_key`, Postgres password, bootstrap
admin password/token, the OIDC `client_secret`) are SOPS-encrypted and
injected via `global.env` + `secretKeyRef`, the same pattern used for
Grafana's own admin credentials in PR 6.

## Consequences

- Rebuilding the identity object graph (provider, application) from
  scratch is a `git push`, not a checklist of UI clicks — verified by
  actually deleting nothing and instead re-triggering the blueprint apply
  via Authentik's API mid-build and confirming it converges to the same
  state.
- Authentik's own blueprint watcher (inotify/poll on the mounted secret
  volume) is a second reconciliation loop layered on top of Flux's —
  after Flux updates the underlying `Secret`, Authentik still needs to
  notice the file changed before re-applying. In practice this took
  longer than expected once during setup; the blueprint's `/apply/` API
  endpoint was used to force it rather than wait.
- Grafana's `auth_url` (browser-facing) and `token_url`/`api_url`
  (Grafana-backend-only, cluster-internal DNS) are deliberately different
  addresses — the browser and Grafana's server don't have the same
  network view of Authentik. On `kind`, `auth_url` only resolves while
  `authentik-server` is port-forwarded to `localhost:9000`; this is a
  dev-only limitation to revisit once Authentik has a real ingress.
- Local admin/password login on Grafana was deliberately left enabled
  (`disable_login_form: false`) rather than forcing OIDC-only, so a
  broken OIDC config can't lock out access to a dev cluster.

## Incidents during setup (kept for the record, not smoothed over)

Three real, distinct bugs were hit and fixed while wiring this up —
documented here rather than only in commit messages, since each reveals
something non-obvious about Authentik or this network:

1. **`grant_types: []`** — the blueprint didn't set `grant_types`
   explicitly, and it does not default to anything usable. Authentik
   rejected every `authorization_code` request with `Invalid grant_type
   for provider` until `grant_types: [authorization_code, refresh_token]`
   was added explicitly.
2. **Missing `property_mappings`** — with none attached, the userinfo
   endpoint returned no `email` claim, so Grafana fell back to a
   Google-OAuth-style `<api_url>/emails` sub-resource that doesn't exist
   on Authentik (`404`), and login failed with "malformed request" /
   `InternalError`. Fixed by attaching Authentik's default managed scope
   mappings (`scope-openid`, `scope-email`, `scope-profile`) to the
   provider.
3. **SSH to GitHub blocked on this network** — unrelated to Authentik,
   but discovered while iterating on this PR: Flux's `GitRepository` used
   an SSH deploy key (from the original `flux bootstrap`), and this
   network blocks the SSH protocol entirely (both port 22 and
   `ssh.github.com:443` time out, while plain HTTPS works). Flux was
   re-bootstrapped with `--token-auth` to use HTTPS + a GitHub PAT
   instead. This is now a portability note for `docs/decisions/0001-use-flux.md`-adjacent
   context: SSH-based bootstrap is not safe to assume works on every
   network.
