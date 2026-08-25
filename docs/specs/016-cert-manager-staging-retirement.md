# Cert-manager Staging Retirement

## Purpose

Record why the permanent Let's Encrypt staging path was removed and define the current
production-certificate boundary. The staging issuer and certificate were rollout proof,
not a useful standing service dependency.

## Retired staging design

The foundation rollout used a `letsencrypt-staging` `ClusterIssuer` and a separate
staging wildcard `Certificate` to prove Cloudflare DNS-01 issuance before requesting the
production certificate. No source-managed Gateway, Ingress, or workload referenced the
staging Secret. Git does not establish whether an untracked or external live consumer
ever used it.

Keeping those resources in desired state after the proof would retain recurring ACME
account and DNS challenge activity without protecting a source-managed served route. A
successful staging renewal also could not prove production renewal because the two
issuers used different ACME endpoints and accounts. The repository therefore removed the
permanent staging `ClusterIssuer`, staging `Certificate`, and their Kustomize references.

Current validation rejects the retired issuer name, staging certificate name, and
staging Secret name anywhere in Kubernetes source. A future staging issuance experiment
must be temporary and deliberate rather than standing Flux-managed state.

## Decision method and retirement gate

Three credible choices were considered:

| Choice | Decision and rationale |
| --- | --- |
| Keep a permanent staging canary | Rejected. It would continue ACME and DNS challenge work but would exercise neither the production account nor a served production route. |
| Remove staging immediately from source | Rejected as unsafe without a live inventory. Source inspection could not exclude a live consumer or a CertificateRequest created outside the expected ownership chain. |
| Retire standing staging state after a bounded inventory, and recreate it temporarily when needed | Chosen. It removed recurring unused state while preserving a deliberate future issuance test path. |

The historical pre-prune safety gate was a read-only inventory of every live
`Certificate` and `CertificateRequest` that referenced `letsencrypt-staging`. Only the
expected staging wildcard and CertificateRequests owned by it were admissible. Any
unrelated consumer stopped removal for review. This gate mattered because the source
finding was narrower: no source-managed Gateway, Ingress, or workload used the staging
Secret. Git could not prove that no other live consumer existed.

The repository does not retain proof that this inventory ran. The gate records the
evidence required to authorize retirement; it is not a claim that the live check or later
pruning completed.

## Current production boundary

The cert-manager source has four distinct reconciliation boundaries:

1. `cert-manager` installs the CRDs, controller, webhook, and cainjector.
2. `cert-manager-config` supplies the SOPS-encrypted Cloudflare credential and the
   `networking` namespace.
3. `wildcard-certificate` supplies only the `letsencrypt-production` issuer and the
   `networking/wildcard-lab-supermorphic-com` certificate.
4. `cert-manager-monitoring` supplies the controller `ServiceMonitor` after both
   cert-manager and kube-prometheus-stack are ready.

The production certificate uses DNS-01, an ECDSA P-256 private key with rotation policy
`Always`, and Secret `wildcard-lab-supermorphic-com-tls`. The shared internal Gateway
references that Secret for its HTTPS listener. These source identities form the current
served-certificate contract; there is no staging resource in the request path or the
renewal alert.

The Cloudflare credential remains encrypted and scoped outside the certificate object.
Removing staging did not change the production issuer, certificate, DNS name, private-key
policy, or Gateway reference.

## Monitoring separation

The cert-manager Helm Kustomization is a foundation component that can reconcile before
Prometheus Operator CRDs exist. It therefore does not create a chart-managed
`ServiceMonitor` or `PodMonitor`. The separate `cert-manager-monitoring` Kustomization
depends on both cert-manager and kube-prometheus-stack and scrapes the controller's
`http-metrics` port once per minute.

The ServiceMonitor uses `honorLabels: true` so cert-manager's certificate `name` and
`namespace` exporter labels are not replaced by scrape-target labels. Those two labels
are the stable certificate identity used by the rules. The alerts application depends
on that monitoring layer and selects the production certificate by
`namespace="networking", name="wildcard-lab-supermorphic-com"`.

## Production alert contract

Three rules cover the one production wildcard certificate:

| Alert | Severity | Condition |
| --- | --- | --- |
| `WildcardCertificateExpiringSoon` | Warning | Remaining lifetime is less than 14 days and more than 3 days for 15 minutes |
| `WildcardCertificateExpiryCritical` | Critical | Remaining lifetime is 3 days or less for 15 minutes |
| `WildcardCertificateExpiryMetricMissing` | Warning | The exact production certificate metric is absent for 5 minutes |

The warning range excludes the critical range. Normal renewal updates the expiry
timestamp on the same certificate identity and clears the warning. The missing-metric
rule does not treat a metric for another namespace or certificate as a substitute.

Promtool fixtures cover the 14-day and 3-day boundaries, renewed and expired values,
warning/critical exclusivity, and exact-identity absence. These tests establish rule
semantics over synthetic metrics; they do not prove that the live controller completed
an ACME renewal.

## Evidence model

The design keeps four evidence classes separate:

| Evidence | What it establishes | What it does not establish |
| --- | --- | --- |
| Current repository source and source validators | Production identities, monitoring dependencies, alert wiring, and absence of staging desired state | Historical inventory execution, Flux pruning, live resource absence, or Secret cleanup |
| Promtool fixtures | Alert behavior for synthetic timestamps and exact metric identities | ACME success, certificate renewal, or Gateway reload |
| Pinned cert-manager API, metrics source, and documentation | The controller model: a `Certificate` maintains its named Secret, renewal updates expiry state, and deletion can leave the Secret when owner references are not enabled | What happened on this cluster |
| The read-only live verifier, when actually run | Present readiness, target health, one future production expiry series, absence of the exact retired Certificate and ClusterIssuer, and loaded rule health | Every historical CertificateRequest or Secret reference, historical pruning, a natural renewal, or serving the renewed bytes |

The verifier's presence in Git is only proof of its contract. It is not evidence that the
verifier ran against the current cluster. Likewise, synthetic renewal data proves that a
newer timestamp on the same identity clears the warning; it is not an observed renewal.

## State and authority boundary

The repository removed the staging `Certificate` and `ClusterIssuer` from desired state
so Flux reconciliation and pruning could retire those source-managed resources. Current
Git proves their source absence, but it does not prove that reconciliation completed or
that the live resources are absent. Secrets that may have been created by the retired
certificate are live-state artifacts, not current Git resources. Certificate Secret
owner references were not enabled in the retired design, so documented controller
behavior permits such a Secret to survive Certificate deletion. Git cannot prove a
Secret's presence, references, or removal. Any orphan cleanup remains an operator-owned
action after exact live reference checks and without exposing Secret contents.

The original continuity evidence plan paired a pinned upstream behavior oracle with
observation of the next natural production renewal. It explicitly rejected forcing a
renewal only to test alerting. The repository retains the upstream model and synthetic
alert tests, but not proof that a natural renewal was observed, that ACME succeeded for a
particular renewal, or that the Gateway reloaded renewed certificate bytes.

Production continuity depends on normal cert-manager renewal plus advance expiry and
missing-telemetry alerts. The design accepts loss of the permanent staging canary because
that canary did not exercise the production account and no source-managed served route
referenced its Secret. Certificates outside cert-manager, general Longhorn health, and
Trivy findings remain outside this boundary.
