# Alerting Architecture

## Intent and ownership

Custom Prometheus alerts have one source, validation, and delivery model. Each monitored
domain owns an alerts Flux application under `kubernetes/apps/<domain>/alerts/`, with
small subject-specific rule files in the `monitoring` namespace. Source and fixtures own
exact alert names, expressions, holds, and labels; this spec owns failure interpretation
and placement constraints.

Separate alert applications depend on the Prometheus foundation. This keeps missing
Prometheus CRDs from blocking ordinary application reconciliation. Applications with a
ServiceMonitor still retain that dependency. The common namespace organizes rules;
Prometheus discovers them cluster-wide. A global rules application would erase useful
domain ownership, while rules beside every workload would duplicate validation and
bootstrap coupling.

Ownership moves are delete-plus-create and can cause temporary rule absence. Keep them
separate from expression changes. Validate each exact deployed `PrometheusRule.spec`
with promtool and domain fixtures, reject unwired/incorrectly placed rules, and require
coverage by alert name. File-level coverage cannot catch an untested rule added to an
already-tested file. Fixtures need independent firing, hold, recovery, exclusion, and
missing-series cases; renders do not prove live rule loading or delivery.

Prometheus evaluates and Alertmanager owns lifecycle. The synchronous ntfy bridge maps
severity to the established topics, preserving grouping, inhibition, silences, repeats,
and resolution. [Flux signals](005-flux-reconciliation-alerting.md) and
[notification delivery](007-ntfy-notification-architecture.md) retain separate contracts.

## Availability and missing evidence

Gatus endpoint failure and series disappearance are distinct. Generic down expressions
cover reporting endpoints, but a group-wide `absent()` cannot detect one missing endpoint
while peers still report. Explicit expected-series checks protect selected critical
paths and [media integration probes](019-media-integration-health-gatus.md).

The Platform echo probe exercises internal DNS, Gateway, served TLS, route, and backend
as one shared data path; application readiness alone cannot establish it. Important
claims have separate persistence signals. Ordinary application outage is a warning,
while critical signals represent materially different data/privacy or shared-path risk.
Hold windows must tolerate expected single-writer replacement downtime without masking
sustained failure. A successful page or claim-Bound status does not prove restored data.

## Production certificate assurance

Monitor the certificate that actually serves the internal Gateway: production expiry
and exact-identity metric presence replace permanent staging issuance. Staging renewal
uses a different ACME account/endpoint and cannot prove production continuity. A bounded
temporary DNS-01 test remains useful, but recurring unserved staging state is retired.
[Certificate source](../../kubernetes/apps/security/cert-manager/) owns issuer/key/Secret
settings; [security rules](../../kubernetes/apps/security/alerts/) own expiry boundaries.

The foundation cert-manager release must not create Prometheus CRDs during bootstrap.
A separate monitoring layer waits for cert-manager and Prometheus; security alerts wait
for that layer. `honorLabels: true` preserves certificate `name`/`namespace`, so another
certificate cannot substitute for the serving certificate's telemetry. Warning and
critical expiry ranges are exclusive, and a renewed timestamp on the same identity
clears them. Synthetic timestamps prove expressions, not ACME success or Gateway reload.

Source removal of staging objects does not prove live pruning. Old certificate Secrets
can survive deletion without owner references. Operator cleanup requires an exact live
reference inventory; unrelated Certificates/CertificateRequests or consumers stop
removal. No retained evidence proves the old inventory, natural renewal, or serving of
renewed bytes. Do not force renewal merely to prove an alert. Live readiness, expiry-series
presence, natural issuance, and actually served certificate bytes are separate evidence.

## Plex policy denial

`PlexWorkloadPolicyDenied` is a narrow regression warning for repeated Kubernetes-workload
policy denials to Plex. [Networking rules](../../kubernetes/apps/networking/alerts/)
own its expression. It is separate from the
[off-cluster traffic detector](014-plex-remote-access-detection.md).

The long observation window preserves brief import-triggered bursts; the hold does not
mean denials continued throughout it. Destination filtering excludes deliberate Plex
SSDP/UPnP containment and other targets. Matching the namespace label inside the complete
source identity tolerates label reordering; aggregation avoids source-identity churn.
Live diagnostics, rather than metric labels, provide attribution.

A general degraded/total-block classifier was rejected: ingress and egress can both deny,
raw identities change, absent forwarded series are not zero, cumulative history has wrong
recovery semantics, and silent event-driven consumers produce no denial evidence.
Joining more history over the same metrics cannot establish a missing integration test.
The warning neither identifies the enforcing endpoint nor proves complete blockage.

Before policy correction, identify the intended consumer, inspect source egress and Plex
ingress, and confirm application configuration. Keep unintended consumers denied. The
alert authorizes no automatic widening. Fixtures must reject unrelated destinations,
non-workload sources, deliberate multicast, and isolated noise while proving bounded
burst firing and eventual resolution.

## Limits and review

Native Longhorn volume health and Trivy finding alerts remain outside this model; UI
reachability and selected claim checks are not general storage-health assurance. Stronger
integration evidence belongs to application-native tests and authorized workflows, not
an elaborate policy query. Delivery still shares the monitoring/ntfy availability boundary.

Revisit placement if CRD ordering or useful domain failure boundaries change. Broader
policy denial requires independent evidence for containment, identity, absent series,
silent consumers, and recovery. New delivery semantics require a notification decision.
