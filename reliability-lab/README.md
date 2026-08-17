# Reliability lab

Deliberate reliability experiments run against the real `dev-kind`
cluster, proving that a specific operational control actually detects or
recovers from the thing it's supposed to — not just that the PromQL exists.
Distinct from `security-lab/`: these experiments are about application
*correctness* and *operational* response, not about a trust/attack
boundary. A signed, policy-admitted artifact can still be reliability lab
material.

## Labs

- [`aegis-api-slo/`](aegis-api-slo/) — SLO definition, a signed-but-bad
  `v0.1.4` release automatically deployed by Flux Image Automation,
  Prometheus detection, and Git-owned GitOps recovery back to `v0.1.3`.
