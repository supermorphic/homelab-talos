# Spec Review

**Spec:** /Users/ksiggins/Development/homelab-talos.dispatch-policy-denied-alert/docs/decisions/2026-08-13-alerting-architecture.md
**Reviewer:** GPT-5.6-sol, Codex
**Verdict:** Not ready — stage 3 has a false scope bound and leaves matcher, threshold, and time semantics unresolved.

## Findings

### F1 — Defect
**Where:** §6.1 What stage 3 covers, and what it does not  
**Mechanism:** the count of five remaining `CiliumNetworkPolicy` objects is used to conclude that only their five selected workloads can be destinations of workload-sourced `POLICY_DENIED` events  
**Failure:** a policy can enforce egress on its selected source workload. The Plex policy permits only kube-dns and selected public CIDR traffic. A Plex request to another in-cluster workload, such as `media/radarr`, is therefore denied with that workload as the destination. The proposed cluster-wide rule observes a destination outside the claimed five, so its always-firing scope is not bounded as stated.  
**When:** any workload selected by one of the five policies attempts disallowed egress to another in-cluster workload

### F2 — Ambiguity
**Where:** §5 Stage 2 — close the test coverage gap  
**Reading 1:** resource-level coverage checks that each `PrometheusRule` YAML object is associated with at least one promtool test file; adding an untested alert to an already-associated object passes CI  
**Reading 2:** alert-level coverage extracts every `.spec.groups[].rules[].alert` value and requires each alert name to appear in a promtool assertion; adding an untested alert fails CI  
**Different implementations:** the first lint indexes resource files or object names, while the second indexes every nested alert name. The text says both “every `PrometheusRule`” and “a new rule without a test fails CI,” without defining which unit the invariant tracks.

### F3 — Contradiction
**Where:** §4 Stage 1 and §11 Open operator decisions  
**§4 says:** `EncodeBenchmarkJobCompleted` “is deleted rather than moved.”  
**§11 says:** the operator must “Confirm deletion, or nominate a non-alerting channel.”  
**Why both cannot hold:** deletion cannot be a decided stage-1 action while the choice between deletion and retaining the notification remains open.

### F4 — Ambiguity
**Where:** §6 Stage 3 — network policy denial alerting  
**Reading 1:** adopt the handoff’s anchored matcher, `source=~"k8s:.*"`, which requires the serialized identity to begin with a Kubernetes label  
**Reading 2:** use a substring matcher for the Kubernetes namespace label, which admits identities where that label appears later in the serialized label set  
**Different implementations:** these produce different PromQL selectors and match different compound identity strings. The spec requires `=~` but never chooses the regular expression.

### F5 — Ambiguity
**Where:** §6 Stage 3 — `PolicyDeniedSustained`  
**Reading 1:** any positive denial rate sustained for the required `for:` duration triggers the warning  
**Reading 2:** a specified number or rate of denials must be exceeded for that duration  
**Different implementations:** the first rule fires on one continuously recurring denial, while the second remains inactive below its numeric threshold. “Sustained denials” supplies neither the threshold nor the measurement window.

### F6 — Ambiguity
**Where:** §6 Stage 3 — `PolicyDeniedTotalBlock`  
**Reading 1:** `unless` tests the presence of the cumulative forwarded-flow series; one historical forwarded flow can suppress the alert while that series remains present  
**Reading 2:** `unless` compares denial and forwarded-flow increases or rates over a defined lookback; the alert can fire for a current total block even when the integration worked earlier  
**Different implementations:** these use different PromQL operands and give different results after a previously healthy integration becomes fully blocked. The phrases “no forwarded flows at all” and “never worked” do not define the intended time boundary.

### F7 — Ambiguity
**Where:** §4 Stage 1 and §7 Stage 4  
**Reading 1:** certificate-expiry rules belong in a new `kubernetes/apps/security/alerts/` application because cert-manager is in the security domain  
**Reading 2:** certificate-expiry rules belong in `kubernetes/apps/monitoring/alerts/` because that application owns cluster monitoring rules  
**Different implementations:** stage 4 creates different directories, Flux Kustomizations, validator entries, and test filenames. The one-application-per-domain rule does not define whether “domain” means the monitored component’s domain or the monitoring subsystem.

### F8 — Scope
**Type:** Unrequested  
**Where:** §1 Decision and §7 Stage 4  
**Brief says:** “then add in seerr — and audit if we are missing other alerts entirely”  
**Mismatch:** the spec goes beyond recording audit findings and commits stage 4 to implementing Gatus and certificate-expiry alerts while deferring other findings.

## Grounding

### G1 — Spec identity
**Assumption:** the reviewed file is the file described by the request.  
**Checked:** SHA-256 of the complete 301-line file.  
**Found:** `76258823f3fc1e7f478b60f4c9bdfae81fdeefba86fc024ade920dbd83d237d7`, matching the requested prefix.

### G2 — Existing rule landscape
**Assumption:** nine `PrometheusRule` files exist across four domains, with about fifteen alerts lacking promtool execution.  
**Checked:** every tracked YAML containing `kind: PrometheusRule` and every `alertname` assertion under `tests/prometheus/`.  
**Found:** nine files and 37 alert definitions exist across three top-level application domains: media, monitoring, and networking. Twenty distinct alert names appear in promtool tests; seventeen current alert names do not. Stage 1 removes four untested DDNS alerts and proposes deleting one untested completion alert.

### G3 — Existing organization and validators
**Assumption:** the repository has seven app-local rule files, one media aggregate, one rule under another app’s `config/`, and three promtool validator implementations.  
**Checked:** the nine rule paths and `scripts/validate/{media-alerts,flux-alerts-promql,tailscale-alerts}.sh`.  
**Found:** confirmed. The validators all extract `.spec` and run promtool, but use separate scripts and two test-filename conventions.

### G4 — Flux dependency claims
**Assumption:** qBittorrent ships a `PrometheusRule` without depending on kube-prometheus-stack; ntfy and test-reports must retain that dependency for `ServiceMonitor`; portainer and encode-benchmark do not contain a `ServiceMonitor`.  
**Checked:** the four `ks.yaml` files and their application manifests.  
**Found:** confirmed.

### G5 — Cilium policy inventory
**Assumption:** six `CiliumNetworkPolicy` objects exist, `plex-ddns-drift` owns one, and no `CiliumClusterwideNetworkPolicy` is committed.  
**Checked:** all Kubernetes YAML for both Cilium policy kinds.  
**Found:** confirmed. The conclusion that this limits denial destinations to the five remaining selected workloads is false for the reason in F1.

### G6 — Hubble metric configuration
**Assumption:** drop and flow metrics use identity source context and workload destination context; flow metrics add `type`, `subtype`, and `verdict`, while drop metrics add `reason` and `protocol`.  
**Checked:** pinned Cilium version `1.19.6`, `kubernetes/apps/kube-system/cilium/app/values.yaml`, and the [Cilium 1.19.6 metrics reference](https://docs.cilium.io/en/stable/observability/metrics/).  
**Found:** the metrics and configured contexts are confirmed, and the documented base label sets differ as stated.

### G7 — Missing forwarded-series premise
**Assumption:** a never-successful source/destination pair has no `verdict="FORWARDED"` series, so `== 0` silently returns no result and `unless` is required.  
**Checked:** committed Cilium configuration, existing PromQL fixtures, the Cilium metrics reference, and repository runbooks.  
**Found:** `UNVERIFIED`. PromQL missing-series behavior and the metric’s `verdict` label are established, but committed configuration cannot prove whether the live exporters create, retain, or remove a zero-valued forwarded series for a particular pair. No live Prometheus access was available.

### G8 — Gatus audit
**Assumption:** Gatus defines eighteen endpoints, seven of which are not covered by existing custom alert rules.  
**Checked:** `kubernetes/apps/monitoring/gatus/app/values.yaml` against all 37 custom alerts.  
**Found:** confirmed: four Observability endpoints, `echo`, `longhorn-ui`, and `letsencrypt-acme` lack matching custom endpoint alerts.

### G9 — Media integration monitoring
**Assumption:** Prowlarr, Sonarr, Radarr, Lidarr, and Seerr have no exporter or `ServiceMonitor`, and current checks prove only process or HTTP endpoint health.  
**Checked:** all five application trees, Gatus configuration, `scripts/verify/arr.sh`, and `scripts/verify/seerr.sh`.  
**Found:** confirmed. The proposed exportarr shape, five scrape targets, API-key requirements, and sizing relative to stages 1–4 are `UNVERIFIED`.

### G10 — DDNS deprecation and delivery routing
**Assumption:** `plex-ddns-drift` is superseded but remains deployed, while severity routing already sends critical and warning alerts to their stated ntfy topics.  
**Checked:** the accepted 2026-08-11 decision, monitoring Kustomization, DDNS application files, kube-prometheus-stack values, and `alertmanager-ntfy/app/config.yml`.  
**Found:** confirmed.
