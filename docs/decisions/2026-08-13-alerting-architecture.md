# Alerting architecture — decision

- **Status: Accepted.**

Date: 2026-08-13.
Branch: `dispatch-policy-denied-alert`.

Companion to [Plex remote access detection — decision](2026-08-12-plex-remote-access-detection.md),
which built the first Hubble-derived alerts and exposed the placement question this
record answers.

## 1. Decision

Consolidate every Prometheus alert rule into **one alerts application per domain**,
give every rule promtool coverage, and enforce that coverage with a repository
invariant. Then add the network-policy denial alerting that no rule provides today, close
the probe-without-alert gaps the audit in §7 found, and commit to a fifth stage giving the
media stack its first signal for whether an integration is actually working.

Delivered in five stages. Each stage is independently reviewable and revertible, and
each has its own pull request. Stage 5 is committed here but designed separately: it
needs a metrics source this cluster does not have yet.

Alert *delivery* does not change. Alertmanager, `alertmanager-ntfy`, the severity to
topic routing, and Gatus all stay exactly as they are. This record moves rules and adds
tests; it does not touch how a firing alert reaches a phone.

## 2. Why

Eight `PrometheusRule` files exist across three domains — media, monitoring, and
networking. They were written one at a time,
each following the app in front of it, and three separate organising patterns are now in
use with no rule for choosing between them:

| Pattern | Files |
|---|---|
| Rule inside the app it watches | 6 |
| Domain aggregate app holding only rules | 1 (`media/alerts`) |
| Rule inside another app's `config/` directory | 1 (`flux-alerts.yaml`) |

The rule *content* is good. The problem is that the best pattern — `media/alerts` with a
validator that extracts `.spec` and runs promtool against it — was built three times and
never extracted, so five of the eight files silently miss it. Thirty-three alerts are
defined; twenty alert names are asserted in promtool tests and **thirteen are not**. One
of the thirteen is `EncodeBenchmarkJobCompleted`, which stage 1 proposes removing, so
stage 2's workload is twelve alerts.

Co-locating rules with applications also has a concrete cost. Every Kustomization
shipping a `PrometheusRule` must declare `dependsOn: kube-prometheus-stack`, because
Flux dry-runs all objects in a Kustomization atomically and the CRD must already exist.
That couples ordinary application rollout to the monitoring stack. It is also already
broken once: `media/qbittorrent` ships a rule and does **not** declare the dependency,
so a cold bootstrap would deadlock its entire apply. It survives only because the CRDs
exist in the live cluster.

## 3. The baseline

`kubernetes/apps/media/alerts/` and its three companions are the reference. This
structure does not change; everything else converges on it.

```
kubernetes/apps/media/alerts/
├── ks.yaml                       Flux Kustomization, dependsOn: kube-prometheus-stack
└── app/
    ├── kustomization.yaml
    └── prometheusrule.yaml
scripts/validate/media-alerts.sh  extracts .spec, runs promtool check + test
tests/prometheus/media-alerts_test.yaml
tests/catalog.yaml                validation.media-alerts
```

## 4. Stage 1 — one alerts application per domain

Move every rule into a domain-level alerts application. Rule content is unchanged except
for a uniform `namespace: monitoring`.

```
kubernetes/apps/
├── media/alerts/app/
│   ├── media.yaml                (was alerts/app/prometheusrule.yaml)
│   ├── qbittorrent.yaml          (moved from qbittorrent/app/)
│   └── encode-benchmark.yaml     (moved from encode-benchmark/app/alerts.yaml)
├── monitoring/alerts/app/        NEW
│   ├── flux.yaml                 (moved from kube-prometheus-stack/config/)
│   ├── ntfy.yaml
│   ├── portainer.yaml
│   └── test-reports.yaml
└── networking/alerts/app/        NEW, replaces tailscale-operator/monitoring/
    └── tailscale.yaml
```

Several small rule files inside one application directory, rather than one large file
per domain. Each subject stays readable while the domain remains a single Flux unit, a
single validator invocation, and a single test file.

The three near-identical validators collapse into one parameterised
`scripts/validate/alerts.sh <domain>`, with a catalog entry per domain.

Removed in stage 1: `kubernetes/apps/networking/tailscale-operator/monitoring/` and the
fourth Kustomization in that application's `ks.yaml`, and
`kube-prometheus-stack/config/flux-alerts.yaml`.

An earlier draft of this record also gave stage 1 the removal of the credential-free DDNS
drift exporter, which §1.1 of
[Plex direct remote access — decision](2026-08-11-plex-direct-remote-access.md) had marked
superseded without the removal ever executing. That is no longer outstanding: #230 removed
the application, its rules, its validator, its verifier, its tests, and its catalog
entries, and #229 removed the superseded public Envoy plane alongside it. Both landed on
`main` while this record was in review. Stage 1 inherits the smaller tree they left.

The `dependsOn: kube-prometheus-stack` cleanup is narrower than it first appears. A
`ServiceMonitor` is also a `monitoring.coreos.com` CRD, so any application shipping one
must keep the dependency regardless of where its rules live. Only **portainer** and
**encode-benchmark** can drop it; **ntfy** and **test-reports** own ServiceMonitors and
keep it. The decoupling benefit is therefore real but partial, and the load-bearing fix
is that `media/qbittorrent` stops shipping a CRD it never declared a dependency for.

`EncodeBenchmarkJobCompleted` is **proposed for deletion rather than moved, pending the
§11 decision**. It fires `severity: warning` when a benchmark job **succeeds**, routing an
ordinary event to the alerting path. A completed job is a notification, not an alert; if
it is still wanted it belongs on a different channel. Stage 1 moves it unchanged if the
operator declines the deletion.

## 5. Stage 2 — close the test coverage gap

Every alert that arrives from stage 1 without promtool coverage gets it: the ntfy,
portainer, test-reports, qbittorrent, and encode-benchmark rules.

Coverage means an independent oracle, per the repository validation rule. For each rule,
prove it fires on a synthetic series reproducing the real condition, prove it does *not*
fire on the adjacent healthy series, and prove each guard by reintroducing the defect —
make the rule wrong and confirm the test fails. A test that only asserts the happy path
is not coverage.

Stage 2 adds the invariant that keeps this from recurring, and the unit it tracks is the
**individual alert name, not the rule file**. The lint extracts every
`.spec.groups[].rules[].alert` value from every `PrometheusRule` in the tree and requires
each name to appear in a promtool assertion. File-level association would not achieve the
stated purpose: `media/alerts` already has a test file, so a new untested alert added to
it would pass. A new alert without a test fails CI.

Test files standardise on `tests/prometheus/<domain>-alerts_test.yaml`, resolving the
current split between `_test.yaml` and `.test.yaml`.

## 6. Stage 3 — network policy denial alerting

No rule in this cluster watches `hubble_drop_total`. A `CiliumNetworkPolicy` silently
broke the Seerr to Plex integration, and it went unnoticed for weeks until it was found
by accident. A second instance is live: lidarr is denied and has carried no forwarded flow
to Plex for the whole period measurement exists.

Neither was ever in the allow-list. `git log --all -S'lidarr'` on
`kubernetes/apps/media/plex/app/ciliumnetworkpolicy.yaml` returns nothing — lidarr has
never appeared in that file. The allow-list was derived from the phase-1 Hubble capture
recorded in [Plex containment capture](2026-08-03-plex-containment-capture.md), whose
prerequisite list named an Apple TV session, a Plexamp session, a native Sonos session, a
Tautulli poll, a Homepage widget refresh, a Gatus probe, and kubelet probes, "and nothing
else." Seerr and lidarr were not among the consumers exercised, so neither was observed
and neither was admitted. An allow-list built from observation is only as complete as its
capture window, and lidarr is the second miss from the same window.

Two rules, in `networking/alerts/app/network-policy.yaml`:

- `PolicyDeniedSustained` — warning. A workload source has sustained denials.
- `PolicyDeniedTotalBlock` — critical. A workload has denials *and no forwarded flows at
  all* to the same destination. That is the "never worked" signature, distinct from
  "degraded", and it is the higher-value rule.

Most denial volume in this cluster is intended. The deliberate SSDP and UPnP multicast
block recorded in [Plex containment capture](2026-08-03-plex-containment-capture.md) is
the largest source of `POLICY_DENIED` events, and a naive threshold rule fires
permanently on it. Separating deliberate denial from broken integration is the whole
task. The exclusion is that deliberate multicast drops carry an empty `destination`,
because `destinationContext` is `workload` and multicast has no workload.

Two implementation facts govern the PromQL, both confirmed against
`kubernetes/apps/kube-system/cilium/app/values.yaml`:

- `source` is a full Cilium identity string carrying the entire label set, so it must be
  matched with `=~` and never `==`. Compound non-workload forms such as
  `cidr:…,reserved:world` also exist.
- **The identity string is not stable for a given workload.** Measured 2026-08-13: lidarr
  appears under two different `source` values that differ only by
  `k8s:io.cilium.k8s.namespace.labels.gateway.supermorphic.com/public-plex=true`. The
  identity embeds the *namespace's* labels, so relabelling a namespace mints a new identity
  for every pod in it. One workload therefore yields two or more series, and an `unless`
  join keyed on the raw `source` treats them as unrelated pairs — leaving the retired
  identity's drop series with no forwarded counterpart. Keying on a stable extracted
  workload name rather than the raw identity is the obvious response, and this record does
  not choose the mechanism. See §11.
- **The denials these rules must catch are bursty, not continuous.** A Plex connection in
  Sonarr, Radarr, or Lidarr fires only on import or upgrade, so it produces a short burst
  of denials and then nothing. Measured 2026-08-13: lidarr recorded 110 denials in 24
  hours, 4 in the preceding 6 hours, and 0 in the preceding hour. A rule built on a short
  window such as `rate(...[5m]) > 0` paired with `for: 30m` would require the denial rate
  to stay above zero for thirty continuous minutes, which an import burst never does — so
  it would not have fired for lidarr at all. The range selector must be long enough that a
  single burst keeps the expression true across the `for:` duration, which points at
  `increase(...[6h])` rather than a short rate. The exact window belongs with the threshold
  question in §11.
- "Zero forwarded flows" cannot be written as `== 0`. When a workload has never reached
  a destination, no `hubble_flows_processed_total{verdict="FORWARDED"}` series exists for
  that pair, and a missing series is not a zero. The rule needs `unless`, with both sides
  aggregated to a common label set first, because the flow metric carries `protocol`,
  `subtype`, and `type` labels the drop metric does not. Written the obvious way, this
  rule never fires and does so silently. **Measured and confirmed on 2026-08-13** against
  the live Prometheus: `hubble_flows_processed_total{destination="media/plex",
  verdict="FORWARDED", source=~".*name=lidarr.*"}` returns **zero series** while lidarr is
  actively being denied, and the same query for seerr returns four. A pair that has not
  succeeded has no forwarded series to compare against, so `== 0` matches nothing.
- **The `unless` operand tests series presence over all retained history, not a rate over
  a lookback window.** That is what approved decision 6 selected — "never worked", not
  "degraded" — and it is stated here because the two forms behave differently and the
  choice is not visible from the rule name. The cost is that an integration which once
  carried a forwarded flow keeps that cumulative series, so this rule will not fire when a
  previously working integration is later blocked completely. That case is not covered by
  stage 3 at all. §11 records it.

Tests must cover: firing on the Seerr signature; **not** firing on the deliberate SSDP
series however high its rate; not firing when forwarded flows are nonzero regardless of
drop volume; and a compound-identity case so a regex regression to `==` is caught.

**Basis and limits of the measurements in this section.** Every figure marked "measured
2026-08-13" comes from read-only PromQL against the live Prometheus through its internal
route, using the scoped `homelab-observer` credential. Neither available context can
port-forward, so the HTTP route was used instead.

The measurement window is short. `hubble_drop_total` and `hubble_flows_processed_total`
first appear at **2026-08-12 09:59**, when the
[Plex remote access detection](2026-08-12-plex-remote-access-detection.md) work enabled
`hubble.metrics` — roughly thirty hours before these queries. A `[30d]` range therefore
returns thirty hours of data, not thirty days. "Lidarr has never reached Plex" is
established only for that window. The missing-series result behind `unless` is unaffected,
because it is a structural property of the metric rather than a function of window length:
lidarr was denied 354 times in the same window that produced no forwarded series for it.

**Absence of denials does not mean absence of configuration.** Sonarr and Radarr produced
no denial series during the window, and the first reading of that — that they had no Plex
connection configured — was wrong. The operator confirms all three of Sonarr, Radarr, and
Lidarr have a Plex Media Server connection under Settings → Connect. That connection is
event-driven: it sends a library-update request to Plex only when media is imported or
upgraded. Sonarr and Radarr imported nothing during the thirty-hour window, so they
generated no traffic to be denied. All three are equally blocked; only lidarr happened to
try.

This is a caution about the metric, not only about these three applications. A silent
consumer is indistinguishable from an absent one in `hubble_drop_total`, so no allow-list
gap can be ruled out by observing no denials.

### 6.1 What stage 3 covers, and what it does not

Five `CiliumNetworkPolicy` objects exist cluster-wide: plex, alertmanager-ntfy, ntfy,
portainer, and test-reports. There is no default-deny policy and no
`CiliumClusterwideNetworkPolicy`, so policy enforcement is opt-in per application.

**All five enforce egress as well as ingress.** A `POLICY_DENIED` event therefore arises
from two directions, not one: traffic *into* a policy-owning workload that its ingress
rules refuse, and traffic *out of* a policy-owning workload to a destination its egress
rules do not permit. The bound is that **one endpoint of the pair is one of those five
workloads** — it is not a bound on the destination. A Plex egress attempt to another
in-cluster workload such as `media/radarr` is denied with `media/radarr` as the
destination, which is outside any set of five.

That still bounds the always-firing risk: five enumerable workloads rather than the whole
cluster, and exactly one broken source-destination pair today.

It does, however, undercut the exclusion this stage relies on. Egress denials to an
in-cluster workload carry a **non-empty** `destination`, so the empty-destination filter
described above does not remove them — and they are deliberate containment, exactly like
the SSDP block, differing only in that the destination happens to be a workload. The
cluster's own record already shows this shape: the multicast drops are themselves egress
denials from Plex.

**Measured 2026-08-13:** the risk is latent, not active. Only two denial destinations exist
across the whole measurement period — absent (6448 events, all Plex multicast egress) and
`media/plex` (1786). No egress denial to an in-cluster workload is occurring today. The
exclusion also works as written: `destination!=""` reduces 8234 events to 1786. Prometheus
treats an absent label as `""` in a matcher, and the destination label on multicast drops
is absent rather than empty, so the filter catches them.

Stage 3 still needs a second exclusion before an egress denial to a workload appears.
This record does not choose one. See §11.

It also bounds the value honestly. These rules detect one specific *mechanism* — a network
policy refusing a consumer — not integration health in general. Nothing in the media
namespace except Plex owns a policy, so a Seerr to Radarr failure, a Prowlarr indexer sync
failure, or a Radarr to qBittorrent failure produces no denial and stays exactly as
invisible after stage 3 as before it. Stage 3 is a regression guard on the Plex allow-list.
It closes the hole that produced both known incidents. It is not the general answer to
"would we notice if an integration died", which is stage 5.

**Stage 3 has a prerequisite outside this repository.** Lidarr is currently neither
working nor cleanly disconnected. If stage 3 merges first, `PolicyDeniedTotalBlock` fires
critical immediately and never clears — the always-firing alert this record exists to
avoid. The operator resolves lidarr first, either by adding it to the Plex ingress
allow-list, the pinned consumer set in `scripts/validate/plex.sh`, and the mutation cases
in `scripts/test/plex-validator-test.sh`; or by removing the Plex connection inside
lidarr so it stops trying. Both are operator decisions. Stage 3 does not begin until one
is done.

## 7. Stage 4 — audit findings and gap closure

`defaultRules.create: true` in kube-prometheus-stack covers generic Kubernetes health, so
the gaps below are specific rather than total.

**Probed but never alerted.** Gatus runs eighteen endpoints across five groups. Rules
exist only for the Media group and for two Platform endpoints. These seven are probed,
scraped, and ignored:

| Group | Endpoints |
|---|---|
| Observability | grafana, prometheus, alertmanager, test-reports |
| Platform | echo |
| Storage | longhorn-ui |
| External | letsencrypt-acme |

`echo` deserves particular attention. Its own comment describes it as proving "the Envoy
gateway data path + wildcard TLS end to end" — it is the synthetic check for the ingress
path every other internal service depends on, and nothing alerts on it failing.

**Domains with no rules at all.** `security` holds cert-manager and trivy-operator and
has zero `PrometheusRule` files, so no certificate expiry alerting exists — a silent
failure with a hard deadline. Longhorn has zero rules despite exporting its own metrics,
so volume degradation and replica loss are unobserved.

**No `runbook_url` annotation anywhere.** Triage currently lives inline in `description`,
which works but caps at a sentence or two. Rules whose triage exceeds that should point
at a runbook instead.

Stage 4 closes the Gatus gap and adds certificate expiry alerting. Longhorn volume health
and trivy findings are named here and deferred: both need their own metric survey, and
bundling them would make this stage unreviewable. Deferred explicitly, not silently
dropped.

Placement follows the §4 rule, which puts an alerts application in the domain of the thing
it monitors — media rules under `media`, tailscale rules under `networking`. Certificate
expiry watches cert-manager, which lives in `security`, so stage 4 creates a fourth alerts
application at `kubernetes/apps/security/alerts/`. The Gatus-derived rules stay in
`monitoring/alerts`, because Gatus is the monitored component in that case. §4 enumerates
three alerts applications because it describes only the rules that exist today; stage 4
adds the fourth.

## 8. Stage 5 — integration health for the media stack

Committed here, designed separately.

The four `*arr` applications monitor **process liveness and nothing else**. Each has an
identical five-file directory with no `CiliumNetworkPolicy`, no `ServiceMonitor`, and no
metrics exporter. Their entire alerting surface is a Gatus `/ping` probe folded into the
group-wide `MediaEndpointDown` rule. `scripts/verify/arr.sh` checks Kustomization
readiness, HelmRelease readiness, route acceptance, DNS, and a `200` from `/ping`.

Every integration between them is unmonitored and always has been: Prowlarr syncing
indexers to Sonarr, Radarr, and Lidarr; Radarr reaching qBittorrent; Lidarr and Seerr
reaching Plex. `scripts/verify/seerr.sh` ends by instructing the operator to connect Plex
and Sonarr/Radarr by hand in the Seerr UI, and nothing checks that connection afterwards.

This is the actual root cause of the incident behind stage 3. The Seerr breakage was not
an oversight in one allow-list; it is that this stack has never had a signal for "the
integration is working" as distinct from "the process is up". Stage 3 catches the subset
of that failure mode which happens to cross a network policy. Stage 5 addresses the rest.

Stage 5 needs a metrics source that does not exist today. The `*arr` applications expose
integration state through their own APIs, not through Prometheus, so the likely shape is
exportarr sidecars plus ServiceMonitors across five applications — a larger piece of work
than stages 1 through 4 combined, and one that adds five new scrape targets and a set of
API keys to manage. That sizing is why it is a separate stage with its own decision record
rather than an extension of stage 4.

Nothing in stages 1 through 4 depends on stage 5, and stage 5 depends on stage 1 having
established where its rules would live.

## 9. What does not change

kube-prometheus-stack, Alertmanager, `alertmanager-ntfy`, Gatus, `flux-kube-state-metrics`,
every `severity` label, and the severity to topic routing. Namespace consolidation onto
`monitoring` is cosmetic — `ruleSelectorNilUsesHelmValues: false` means Prometheus loads
rules from every namespace regardless. Its only payoff is deleting the same four-line
"Prometheus discovers this cluster-wide" comment currently restated in four files.

## 10. Risks

Moving a rule between Kustomizations is a delete and a create, not an edit. Between the
two reconciles the rule is briefly absent, so an alert cannot fire during that window.
Stages are ordered so no rule moves in the same pull request that changes its expression.

Stage 1 touches `require_deployed_source` pin lists in `.just/bootstrap.just` and entries
in `tests/catalog.yaml`. Both are enforced, so a missed edit fails CI rather than passing
silently.

This record was written against a tree that still contained the DDNS drift exporter and
the public Envoy plane. #229 and #230 removed both while it was in review, and its counts
were corrected before it was accepted. Anyone reading it alongside an older branch should
expect the smaller numbers here.

## 11. Open operator decisions

1. **Admit Sonarr, Radarr, and Lidarr to the Plex allow-list.** Operator-confirmed on
   2026-08-13: all three have a Plex Media Server connection under Settings → Connect, so
   all three require ingress to `media/plex` on TCP `32400` to notify Plex when new media
   arrives. Prowlarr does not — it manages indexers, owns no library, and has no Plex
   connection to configure. Seerr is already admitted and confirmed working.

   The direction is settled; what remains is execution. Each addition touches three files
   together: the ingress allow-list in
   `kubernetes/apps/media/plex/app/ciliumnetworkpolicy.yaml`, the pinned consumer set in
   `scripts/validate/plex.sh`, and the mutation cases in
   `scripts/test/plex-validator-test.sh`. PR #225, which admitted Seerr, is the shape to
   follow. Admitting all three in one change avoids repeating this discovery twice more.

   This is a prerequisite of stage 3 rather than part of it. Merging the alerting rules
   while a known consumer is still denied produces exactly the permanently-firing alert
   this record exists to prevent.
2. ~~**Public gateway.**~~ **Resolved before acceptance.** An earlier draft flagged that
   the 2026-08-11 decision marked the public Gateway superseded while
   `kubernetes/apps/networking/public-gateway/` was still present with a Plex route
   attached. #229 removed the plane and its route. No decision needed.
3. **`EncodeBenchmarkJobCompleted`.** Confirm deletion, or nominate a non-alerting
   channel for job-completion notices.
4. **The second exclusion mechanism for stage 3.** All five remaining policies enforce
   egress, so deliberate egress denials to an in-cluster workload carry a non-empty
   `destination` and the empty-destination filter does not remove them (§6.1). Stage 3
   needs a way to separate those from broken integrations, and this record does not choose
   one. Blocks stage 3 alongside item 1.
5. **The `source` matcher form.** The originating handoff specified `source=~"k8s:.*"`,
   which anchors at the start of the serialised identity string. Matching the namespace
   label as a substring admits identities where that label appears later in the set. These
   are different selectors that match different compound identities, and this record does
   not choose between them.
6. **A threshold and range window for `PolicyDeniedSustained`.** "Sustained denials"
   specifies neither a rate nor a count. Whether any positive denial rate held for the
   `for:` duration is enough, or a numeric floor applies, is unchosen.

   Measurement has since made the range window the sharper half of this question. The
   denials worth catching arrive in import-triggered bursts, not continuously (§6), so a
   short rate window combined with the approved `for:` of 30m or more would never fire.
   The window and the threshold have to be chosen together.
7. **The previously-working blind spot.** As selected, `PolicyDeniedTotalBlock` cannot
   fire for an integration that once carried a forwarded flow and is later blocked
   completely (§6). Accept that limitation, or commission a rule that covers it.
8. ~~**An unverifiable premise.**~~ **Resolved 2026-08-13.** The claim that a
   never-successful pair has no `FORWARDED` series was measured against the live
   Prometheus with a read-only credential and holds: zero series for lidarr while it was
   being denied, four for seerr. `unless` is required; `== 0` matches nothing. Recorded in
   §6. No decision needed.
9. **Keying the join on an unstable identity.** The Cilium `source` identity embeds
   namespace labels, and lidarr already appears under two identities that differ only by a
   namespace label added later (§6). Stage 3 must key its join on something stable — an
   extracted workload name — and this record does not choose the mechanism. Blocks stage 3
   alongside items 1 and 4.
