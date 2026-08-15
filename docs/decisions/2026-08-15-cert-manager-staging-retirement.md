# Cert-manager staging retirement — decision

- **Status: Accepted.** Approved by the operator on 2026-08-15.

Date: 2026-08-15.
Branch: `dispatch-alerting-gap-closure`.

Builds on [Alerting architecture — decision](2026-08-13-alerting-architecture.md),
especially Stage 4 in §7. This record does not revise that accepted decision. It records
the separate lifecycle decision needed before Stage 4 changes cert-manager resources.

## 1. Context

The foundation rollout used a Let's Encrypt staging `ClusterIssuer` and wildcard
`Certificate` to prove the Cloudflare DNS-01 path before production issuance. That proof
remains deployed after the rollout completed.

The staging certificate has no source-managed Gateway, Ingress, or workload consumer.
It uses a separate ACME endpoint and account from production, so its successful renewal
does not prove that production renewal will succeed. Keeping it permanently deployed
therefore adds issuance and DNS challenge activity without protecting a served route.

The production wildcard certificate is different. Its Secret terminates HTTPS on the
shared internal Gateway and is a high-impact dependency for internal routes. Stage 4 will
alert on that production certificate's expiry and on disappearance of its expiry metric.

## 2. Decision

Retire the permanent staging issuance path:

- remove the staging wildcard `Certificate` from Git;
- remove the `letsencrypt-staging` `ClusterIssuer` from Git;
- keep the cert-manager configuration layer that supplies the encrypted Cloudflare
  credential and the `networking` namespace;
- keep the production `ClusterIssuer`, production wildcard `Certificate`, Secret name,
  DNS name, private-key policy, and Gateway reference unchanged; and
- monitor only the production wildcard certificate in Alerting Stage 4.

A future staging issuance test must be temporary and deliberate. It requires a new,
bounded operator workflow or an accepted repository change; it is not standing cluster
state.

Before the removal is merged, the operator must use a read-only cluster inventory to
verify that no unexpected `Certificate` or `CertificateRequest` references
`letsencrypt-staging`. Only the expected staging wildcard and CertificateRequests owned
by it are permitted before pruning. Any unrelated consumer stops the removal for review.

Flux may prune only the source-managed staging `Certificate` and `ClusterIssuer` after
merge authorization. Secret inspection and deletion remain operator-run. The operator
must confirm that no resource references an orphaned staging Secret before deleting it,
and must not expose its contents.

## 3. Alerting and bootstrap boundary

Certificate-expiry alerting uses cert-manager controller metrics. Metrics discovery must
not add a `ServiceMonitor` to the foundational cert-manager Helm Kustomization because
that Kustomization is installed before the Prometheus Operator CRDs exist during a cold
bootstrap.

Stage 4 must instead use a separate cert-manager monitoring Kustomization. It reconciles
only after both cert-manager and kube-prometheus-stack are ready. The security-domain
alerts application then depends on that monitoring Kustomization and on
kube-prometheus-stack.

The production expiry metric is identified by the `Certificate` object name and
namespace. Normal renewal updates the expiry timestamp on that same object identity.
The implementation must retain an upstream-source oracle for the pinned cert-manager
version and a live check at the next natural renewal. It must not force a renewal only to
test alerting.

## 4. Consequences

The cluster no longer performs recurring ACME and DNS-01 work for an unused staging
certificate. It also loses a permanent staging canary, which is accepted because that
canary did not exercise the production ACME account or serve traffic.

Production continuity instead relies on cert-manager's normal automatic renewal plus
advance expiry alerts. Stage 4 uses a warning window early enough for investigation and
a separate critical window near expiry. A five-minute missing-metric alert detects loss
of the certificate telemetry itself.

Source removal can leave staging Secrets because certificate Secret owner references are
not enabled. These Secrets are not an implementation-agent cleanup target. The operator
may remove them only after exact live reference checks.

## 5. Scope

This decision authorizes the later staging-resource retirement and the production-only
certificate-expiry design. This decision-only change does not remove resources, add
alerts, modify Flux reconciliation, or mutate the cluster.

Longhorn health, Trivy findings, and certificates managed outside cert-manager remain
deferred. The Alerting Stage 4 implementation specification and plans remain uncommitted
under `.tmp/` as required by repository policy.
