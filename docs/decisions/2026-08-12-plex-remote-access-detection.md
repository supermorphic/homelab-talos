# Plex remote access detection — decision

- **Status: Accepted.**

Date: 2026-08-12.
Branch: `plex-remote-access-detection`.

Companion to [Plex direct remote access — decision](2026-08-11-plex-direct-remote-access.md),
whose §7.1 defers this design and makes it a precondition of stage 3.

## 1. Decision

Collect Hubble flow metrics from Cilium, scrape them into the existing Prometheus, and
alert on two network-layer conditions at Plex's `32400`: a connection flood and a probe
surge. Route both through the existing Alertmanager and ntfy path. Prove every rule with
promtool unit tests, then exercise the whole chain against synthetic abuse generated
from the LAN.

Attribution stays out of Prometheus. Alerts answer *when* and *how much*; the existing
`just kube plex-network-observe` answers *who*.

## 2. Scope

Covered, because §7.1 names them and the operator selected them:

- **Probing and scanning** — connection attempts that never become sessions.
- **Connection flood** — volumetric abuse of the port.

Deferred explicitly, not silently dropped:

- **Repeated authentication failures.** Plex writes these to its config PVC and this
  cluster runs no log collector. Detecting them needs either a Tautulli-API exporter or
  a log path, and either is a larger project than this gate justifies. Plex's own
  account lockout remains the only control.
- **Bandwidth saturation.** Partly bounded already by Plex's per-user remote stream
  limit of `2` recorded in §10 of the 2026-08-02 design. A real signal needs session
  data this design does not collect.

Both remain unobserved after this work. Stage 3 proceeds with that stated, or it does
not proceed.

## 3. Why nothing observes this port today

Hubble is enabled and its relay runs, but `hubble.metrics` is unset and the Cilium
agent's own `prometheus.enabled` is `false`, so Cilium exports nothing and no
ServiceMonitor scrapes it. Only three ServiceMonitors exist cluster-wide — ntfy,
plex-ddns-drift, and test-reports — and none targets `kube-system`.

Of Plex specifically, Prometheus holds a Gatus `/identity` probe result, PVC-bound
status, and the DDNS drift exporter's comparison. Nothing about sessions, connections,
source addresses, or bytes at `32400`.

No log collector exists. Loki, Promtail, Vector, Alloy, and fluent-bit are all absent
from the tree. Every existing detection in this cluster is metrics-based, and this one
must be too.

## 4. Signals

Available only after enabling `hubble.metrics`, which is the whole of stage A:

| Metric set | Gives |
|---|---|
| `flow` | Flow counts by verdict, with source and destination context |
| `tcp` | TCP flag counts — the difference between attempts and established sessions |
| `drop` | Policy-denied counts by reason |

Context is set to `destinationContext=pod`, `sourceContext=identity`. Identity context
collapses every off-cluster address to `reserved:world`, so the series count is
independent of how many hosts probe the port.

`sourceContext=ip` is rejected. It would mint a Prometheus series per source address on
an Internet-facing port, against a single-replica Prometheus with 50GiB and 30 days of
retention. The precision it buys is available on demand from Hubble itself and is not
worth an unbounded cardinality surface. A source validator asserts the setting is never
`ip`, and that guard is proven by reintroducing the defect.

## 5. Architecture

Two code changes, separately reviewable, in order — stages A and B of §11. Stage C adds
no source and is an operator procedure. Stage B cannot be written honestly before stage
A has merged, because the exact series and labels Hubble emits under this configuration
must be observed rather than predicted. An alert rule written against
predicted series is not detection; §7.1 already says an untested rule is not detection,
and this is the same principle one step earlier.

### Stage A — enablement

`kubernetes/apps/kube-system/cilium/app/values.yaml` gains a `hubble.metrics.enabled`
list carrying the metric sets and contexts of §4. Setting that list is sufficient for the
chart to render the headless `hubble-metrics` Service in `kube-system` on port `9965`,
verified by rendering the pinned 1.19.6 chart.

The chart's own `hubble.metrics.serviceMonitor.enabled` is **not** used, and the values
file deliberately contains no ServiceMonitor. `just bootstrap cilium` installs Cilium
from this same values file onto a bare cluster, where the Prometheus operator CRDs do
not yet exist; a chart-rendered ServiceMonitor would fail that install on `no matches for
kind ServiceMonitor`. The failure would be invisible until a rebuild — the moment
bootstrap most needs to work. Keeping the values file free of CRD-dependent kinds is
what preserves disaster recovery, and a validator assertion holds it that way.

The ServiceMonitor is instead written by hand under
`kubernetes/apps/kube-system/cilium/monitoring/` and applied by its own `cilium-monitoring`
Kustomization with `dependsOn: kube-prometheus-stack`. This mirrors
`tailscale-operator-monitoring`, which exists for the same reason. It selects the chart's
Service by `k8s-app: hubble` on the named port `hubble-metrics`.

Stage A rolls the Cilium DaemonSet across all three nodes. The operator accepted that as
an ordinary Flux change rather than a staged rollout. The rollback is reverting the
commit; no state outside Git is created, and the metrics port is additive.

Gate: the Hubble series are present in Prometheus and the ServiceMonitor is being
scraped. Stage B is written against what is observed there.

### Stage B — detection

A `plex-remote-access` group extends
`kubernetes/apps/media/alerts/app/prometheusrule.yaml` rather than becoming a new app.
That reuses a validator, a promtool test file, a `just` recipe, and a catalog entry that
already exist and already run in `just ci`, and it avoids the media rule-file inventory
assertion in `scripts/validate/media-alerts.sh` that a new `media/*/prometheusrule.yaml`
would otherwise trip. The cost is that network-flow alerts sit beside Gatus black-box
alerts in one file; at three rules that is the cheaper arrangement.

## 6. Alerts

| Alert | Severity | Condition |
|---|---|---|
| `PlexRemoteConnectionFlood` | `critical` | Sustained connection rate from `reserved:world` to the Plex pod above threshold |
| `PlexRemoteProbeSurge` | `warning` | Elevated connection attempts that do not become established sessions |
| `PlexRemoteFlowMetricsMissing` | `critical` | `absent()` on the Hubble series |

The third is the one this gate actually turns on. A detector that stops silently
converts "no alerts" from evidence into an assumption, and every other rule in this
repository already pairs its primary alert with an `absent()` companion for that reason.

Routing needs no new Alertmanager configuration. `severity: critical` reaches ntfy topic
`critical`, `warning` reaches `homelab`, through the route that already carries every
alert in this cluster.

## 7. Thresholds

Provisional, and stated as provisional. They derive from the local traffic profile, what
the uplink can physically carry, and the per-user remote stream limit of `2`.

They are **not** derived from a measured baseline of remote traffic, because none exists
until the DNAT does and the DNAT is gated on this work. §7.1 forbids requiring one, and
§4 of the companion decision records what happens when a design makes an unobtainable
measurement a prerequisite. They are tuned once real remote traffic exists.

`for:` durations on the `absent()` rule exceed a three-node DaemonSet roll. A shorter
window would flap the alert on every future Cilium change and train the operator to
ignore it, which would defeat the rule more thoroughly than not having it.

## 8. Rate limiting

Not achievable without reintroducing a proxy in front of Plex, which is precisely what
the companion decision removed, and for a reason that has not changed: a proxy
terminates the connection with a certificate Plex clients do not trust. Recorded as a
deliberate non-goal. The available bound stays Plex's per-user remote stream limit.

## 9. Accepted residual risk

- **Thresholds are public.** The PrometheusRule is committed for Flux to reconcile, so
  its thresholds are readable by anyone. This is inherent to GitOps on a public
  repository and is accepted rather than mitigated; the alternative is detection that
  is not reconciled from Git.
- **One notification path.** If ntfy is down, these alerts do not arrive. `NtfyDown`
  already covers that failure and no second path is added here.
- **Aggregate-only attribution.** Prometheus cannot say which address caused an alert.
  That is the deliberate consequence of §4 and the reason the response procedure begins
  with `plex-network-observe`.
- **False positives on legitimate heavy use.** Expected with provisional thresholds.
  The runbook's first step is observation, not action.

## 10. Validation

- A source validator asserting the Cilium `hubble.metrics` shape: the metric sets, both
  contexts, and that `sourceContext` is never `ip`.
- A source validator asserting the values file declares no ServiceMonitor, preserving
  bootstrap on a cluster without the Prometheus CRDs.
- A rendered-chart assertion that the `hubble-metrics` Service exists and that the render
  emits no ServiceMonitor — an independent oracle, since the render is the chart's own
  interpretation of the values rather than a re-read of what was written.
- promtool unit tests for every alert, each exercised silent → pending → firing →
  resolved, with `absent()` cases covering an unrelated series present and the target
  series absent.
- PromQL under test extracted from the live manifest with `yq`, never copied into the
  test file, matching the established pattern in `scripts/validate/media-alerts.sh` and
  `scripts/validate/tailscale-alerts.sh`.
- `mise exec -- just ci` before every pull request.

Every validator assertion must encode a genuine invariant or use an independent oracle.
Where a guard is added, it is proven by reintroducing the defect and confirming the
suite fails.

## 11. Staging and gates

| Stage | Steps | Gate to proceed |
|---|---|---|
| **A — Enablement** | Cilium `hubble.metrics`; hand-written ServiceMonitor in its own Kustomization; cardinality and bootstrap guards | Hubble series present in Prometheus and being scraped |
| **B — Rules** | Alert group, promtool tests, response runbook | `just ci` green; every alert proven to fire in unit test |
| **C — Exercise** | Synthetic probe and flood against `192.168.90.31:32400` from a LAN host | Both alerts fire and arrive at ntfy |

Stage C closes §7.1's gate and unblocks stage 3 of the companion decision.

The abuse traffic must originate off-cluster to carry `world` identity, so it cannot be
an in-cluster recipe with a run-scoped pod — it is an operator procedure from a LAN
machine, documented in the runbook. This is possible without any Internet exposure
because Cilium's `world` entity includes LAN addresses, so `192.168.90.31:32400` is
already reachable from the LAN. The reachability that the stage-1 change created is what
makes this gate testable before any exposure exists.

## 12. Decision record

| Decision | Outcome |
|---|---|
| Detection scope | Probing and connection flood only |
| Auth failures, bandwidth saturation | Explicitly deferred; unobserved after this work |
| Signal source | Hubble flow metrics via Cilium; `flow`, `tcp`, `drop` |
| Source context | `identity`; `sourceContext=ip` rejected and guarded against |
| Attribution | Out of band, via existing `plex-network-observe` |
| Cilium rollout | Ordinary Flux change; revert the commit to roll back |
| ServiceMonitor | Hand-written in its own Kustomization gated on kube-prometheus-stack; chart's `serviceMonitor.enabled` rejected to keep bootstrap working without the Prometheus CRDs |
| Rule placement | Extends the existing `media/alerts` PrometheusRule |
| Alert routing | Existing severity route to ntfy; no new configuration |
| Thresholds | Provisional, from local profile and link capacity; tuned after real traffic |
| Rate limiting | Deliberate non-goal; needs a proxy this design removed |
| Log collection | Still absent; not introduced here |
| Proof | promtool unit tests, then synthetic abuse from a LAN host |
