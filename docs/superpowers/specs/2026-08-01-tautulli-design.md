# Tautulli Plex analytics — design

Status: approved design, pending implementation plan.
Date: 2026-08-01.
Branch: `tautulli-monitoring-addition`.

## 1. Purpose

Add Tautulli to the media stack as a Plex analytics and history service: who watched
what, when, on which device, and how it was delivered (direct play vs transcode).

Nothing in the cluster currently has Plex *session* awareness. Gatus proves Plex answers
HTTP; kube-state-metrics proves its pod and claim exist. Neither can see a stream. Tautulli
fills exactly that gap and nothing else.

The watch history is **greenfield** — no prior Tautulli database is imported, so history
begins at rollout.

This work also closes an unrelated gap found while scoping: media services have Gatus
probes but no alert rules, so a media outage today turns a dashboard tile red and notifies
nobody.

## 2. Scope

In scope:

- Tautulli Flux application (`kubernetes/apps/media/tautulli/`).
- Media availability alerting (`MediaEndpointDown`) covering every media Gatus endpoint.
- Persistence alerting for the two claims holding irreplaceable state (Plex, Tautulli).
- promtool unit tests for the new alert rules.
- Validation, verification, and a parameterized bootstrap recipe.
- Homepage widget (secret recipe, Secret, env var) and Gatus endpoint.
- Rego policy contract and tests.
- Operator documentation.

Out of scope (deliberately deferred):

- **ntfy notifications from Tautulli.** See D3 and §10.
- Prometheus stream/transcode metrics via a sidecar exporter.
- Tautulli newsletters.
- Any watch-history import.
- Chainsaw smoke, resilience, or automated E2E coverage. See D8.
- Retrofitting qBittorrent's existing alert rules into the new promtool harness.

## 3. Decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | Deploy Tautulli as a structural clone of Seerr | Both are config-only media apps consuming the Plex API. Divergence would be unjustified. |
| D2 | Pin `ghcr.io/home-operations/tautulli:2.17.2` | Verified present in the registry. No Renovate in this repo — pins are manual. |
| D3 | No ntfy integration | `docs/ntfy-startup-guide.md` §G forbids direct Plex/`*arr` ntfy producers. The unique alerts Tautulli could add (buffering, remote-access) are soft, and the declarative-sync cost is high. See §10. |
| D4 | Tautulli mounts no shared media claim | It reads the Plex API, never the files. Enforced by adding it to `config_only_apps` in Rego. |
| D5 | Generic `MediaEndpointDown` over `group="Media"` rather than per-app rules | One rule covers every current and future media endpoint. Less code, strictly more coverage. |
| D6 | `MediaEndpointDown` uses `for: 15m`, severity `warning` | Plex's own rollout can be legitimately down 5–8 minutes; see §7.1. Media availability is not a data-loss or privacy event, so it routes to the `homelab` topic. |
| D7 | New alert rules get promtool unit tests | An alert added because nothing pages today is indistinguishable from the status quo if its label matchers are wrong. Untested rules give false confidence. See §7.3. |
| D8 | No Chainsaw smoke, resilience, or E2E coverage | Smoke would be a strict subset of the verifier; resilience would retest Longhorn+Recreate already covered by `plex-cross-node-reschedule`; a real E2E needs live playback and is infeasible. See §8. |
| D9 | Bootstrap via a parameterized `media-app` recipe, not a third copy | `seerr` and `flaresolverr` bootstrap recipes are 62/64 lines differing only in app name. This is the D6 signal from the Lidarr spec. See §6.2. |
| D10 | Existing `seerr`/`flaresolverr` bootstrap recipes are left untouched | Both apps are live, so their recipes are dormant recovery paths. Rewriting working recovery code buys tidiness and risks a break discovered only during an incident. |
| D11 | Docs extend `docs/arr-stack-startup.md` | That file already documents Seerr, which is not an `*arr` either. A one-app doc file would fragment the runbook. |

## 4. Architecture

Tautulli runs in the `media` namespace as a single-replica Deployment with
`strategy: Recreate` over a ReadWriteOnce Longhorn config PVC — its SQLite database is
single-writer, the same constraint as Seerr and the `*arr` apps.

It reaches Plex at `http://plex.media.svc.cluster.local:32400` over cluster DNS,
in-namespace. It also egresses to `plex.tv` for account/token validation.

Tautulli does **not** mount Plex's config PVC. That volume is `ReadWriteOncePod`, so only
the Plex pod may ever mount it. This permanently rules out Tautulli's "Plex Logs" viewer —
the one feature an operator would reasonably expect to work and which will not.

| Property | Value |
|---|---|
| Namespace | `media` |
| Image | `ghcr.io/home-operations/tautulli:2.17.2` |
| Service port | `8181` |
| Hostname | `tautulli.lab.supermorphic.com` |
| Health endpoint | `/status` (unauthenticated, returns JSON 200) — unverified on this image, see §10 |
| Config PVC | 5Gi, `longhorn`, RWO, `helm.sh/resource-policy: keep`, at `/config` |
| Rendered PVC name | `media/tautulli` (verified by `helm template`) |
| `dependsOn` | `internal-gateway`, `media` |
| Pod security | `runAsUser/Group/fsGroup: 568`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]` |

`dependsOn` is `media`, not `media-storage` (Tautulli mounts no shared claim) and not
`plex` (Seerr sets the precedent that a Plex-consuming app declares no Flux dependency on
Plex; ordering is about namespace and gateway readiness, not app liveness).

The Plex server URL, its token, and the Tautulli API key are first-run settings persisted
in the config PVC. There is no config-as-code for them, exactly as with Lidarr's root
folders.

## 5. Alerting

### 5.1 Ownership split

Availability is a namespace-wide concern; persistence is per-app.

| File | Rules |
|---|---|
| `kubernetes/apps/media/namespace/app/prometheusrule.yaml` | `MediaEndpointDown`, `MediaEndpointsProbeMissing` |
| `kubernetes/apps/media/plex/app/prometheusrule.yaml` | `PlexPersistentVolumeClaimNotBound` |
| `kubernetes/apps/media/tautulli/app/prometheusrule.yaml` | `TautulliPersistentVolumeClaimNotBound` |

The namespace-wide rule lives in `media/namespace/app/` because the `media` Kustomization
is what every media app already depends on.

### 5.2 Rules

| Alert | Expression | For | Severity |
|---|---|---|---|
| `MediaEndpointDown` | `gatus_results_endpoint_success{group="Media", name!="qbittorrent-vpn"} == 0` | 15m | warning |
| `MediaEndpointsProbeMissing` | `absent(gatus_results_endpoint_success{group="Media"})` | 15m | warning |
| `PlexPersistentVolumeClaimNotBound` | `absent(kube_persistentvolumeclaim_status_phase{namespace="media", persistentvolumeclaim="plex", phase="Bound"} == 1)` | 5m | critical |
| `TautulliPersistentVolumeClaimNotBound` | `absent(kube_persistentvolumeclaim_status_phase{namespace="media", persistentvolumeclaim="tautulli", phase="Bound"} == 1)` | 5m | warning |

The `name` label flows through `MediaEndpointDown`, so each failing endpoint produces its
own alert and every future media app is covered the day its Gatus endpoint lands.
`qbittorrent-vpn` is excluded because it already has a dedicated critical rule.

`MediaEndpointsProbeMissing` fires only when *no* Media series exist at all, which makes it
a Gatus-broken canary rather than a per-endpoint check.

### 5.3 Severity rationale

Per `alertmanager-ntfy/app/config.yml`, severity controls the ntfy topic
(`critical` → `critical`, otherwise → `homelab`), the priority (`urgent` vs `default`),
and the tag. `critical` is reserved for events risking data or privacy — an unbound Plex
claim endangers the library database migrated from the Mac mini; a VPN drop is a leak.
Media availability is neither, so it routes to `homelab`, which the `subscriber` identity
reads.

Portainer's existing `critical` down-alert is **not** treated as precedent: it arrived in
#91 with no recorded rationale, immediately after `QbittorrentVpnDown` where critical was
genuinely warranted.

## 6. Repository footprint

### 6.1 Files

New (13):

```text
kubernetes/apps/media/tautulli/ks.yaml
kubernetes/apps/media/tautulli/app/{kustomization,helmrelease,values,httproute,prometheusrule}.yaml
kubernetes/apps/media/namespace/app/prometheusrule.yaml
kubernetes/apps/media/plex/app/prometheusrule.yaml
kubernetes/apps/monitoring/homepage/app/homepage-tautulli.sops.yaml   (operator-generated)
scripts/validate/tautulli.sh
scripts/validate/media-alerts.sh
scripts/verify/tautulli.sh
tests/prometheus/media-alerts_test.yaml
```

Modified (~15):

| File | Change |
|---|---|
| `kubernetes/apps/media/kustomization.yaml` | wire `./tautulli/ks.yaml` |
| `kubernetes/apps/media/namespace/app/kustomization.yaml` | add `prometheusrule.yaml` |
| `kubernetes/apps/media/plex/app/kustomization.yaml` | add `prometheusrule.yaml` |
| `kubernetes/apps/monitoring/gatus/app/values.yaml` | `tautulli` endpoint (activation PR only) |
| `kubernetes/apps/monitoring/homepage/app/deployment.yaml` | `HOMEPAGE_VAR_TAUTULLI_API_KEY`, `optional: true` |
| `kubernetes/apps/monitoring/homepage/app/kustomization.yaml` | add the SOPS resource |
| `.just/repository.just` | `homepage-tautulli-secrets` recipe |
| `.just/bootstrap.just` | parameterized `media-app` recipe |
| `kubernetes/mod.just` | `tautulli-validate`, `tautulli-verify`, `media-alerts-validate` |
| `scripts/validate/plex.sh` | assert the PrometheusRule exists and is wired |
| `tests/catalog.yaml` | `validation.tautulli`, `validation.media-alerts`, `verification.tautulli` + aggregates |
| `tests/policy/media/media.rego` | `required_dependencies`, `config_only_apps` |
| `tests/policy/media/media_test.rego` | Tautulli contract tests |
| `docs/arr-stack-startup.md` | Tautulli runbook section |
| `README.md` | recipe table entries |

### 6.2 Parameterized bootstrap recipe

`bootstrap seerr` and `bootstrap flaresolverr` are 62 and 64 lines whose diff is **only**
the app name and confirmation string. Every structural line is identical: the cleanup
trap, `require_deployed_source`, the suspended-in-Git check, the suspended-in-cluster
check, resume, reconcile, wait, verify.

Tautulli is therefore added through a parameterized `bootstrap media-app <name>` recipe
modeled on the existing `bootstrap arr <app>`, which already proves the form works across
four apps. Per D10, the two existing recipes are not migrated.

### 6.3 Rego contract

Add to `tests/policy/media/media.rego`:

- `required_dependencies`: `"tautulli": {"internal-gateway", "media"}`
- `config_only_apps`: `"tautulli"`

The second entry is load-bearing: it makes the policy actively reject a future edit that
adds `persistence.data` or `persistence.media` to Tautulli. Mounting the media share is the
obvious wrong instinct for a media app, so encoding "this one is config-only" is the
highest-value line in the change. `media_test.rego` gains the mirror of the Lidarr contract
tests, including a denial test for that case.

## 7. Testing and verification

### 7.1 Why `for: 15m`

Plex sets `terminationGracePeriodSeconds: 120` with `strategy: Recreate`, so the old pod
fully terminates before the new one starts, and its startup probe allows
`10s × 30 = 300s`. A routine version bump is plausibly 2 minutes terminating, plus image
pull, plus 1–5 minutes starting: **5–8 minutes of legitimate downtime**. A `for: 5m` window
would fire on every Plex upgrade, and alerts that cry wolf during deploys get muted.

### 7.2 Validation (offline, in `just ci`)

- `validation.tautulli` — `scripts/validate/tautulli.sh`, structurally following
  `validate/seerr.sh`: files exist, wired into the media kustomization, no `decryption`
  block, `chartRef` is `app-template`, Recreate + RWO + longhorn + `resource-policy: keep`
  at `/config`, no `persistence.data`, HTTPRoute host/parent/backend/port, activation-aware
  Gatus and Homepage widget assertions, `kustomize build`, and a pinned `helm template`
  render check.
- `validation.media-alerts` — `scripts/validate/media-alerts.sh`, mirroring
  `validate/tailscale-alerts.sh`.
- Rego policy tests via the existing policy suite.

### 7.3 promtool unit tests

`scripts/validate/media-alerts.sh` extracts the rule `.spec` from the three
PrometheusRule files into a plain rules file next to
`tests/prometheus/media-alerts_test.yaml`, then runs `promtool check rules` and
`promtool test rules`. The PromQL is single-sourced from the manifests — never duplicated
into the test.

Each alert is exercised across three temporal states (before `for:` → silent, at/after →
firing, after recovery → silent), so a `for:` regression fails as surely as a metric typo.
Each `absent()` rule additionally gets an "unrelated object present but the target series
absent" case, proving the matchers *inside* `absent()` are correct rather than merely that
`absent()` works. `MediaEndpointDown` gets a multi-series case proving one alert per
endpoint and that `qbittorrent-vpn` is excluded.

### 7.4 Verification (operator-only, live)

`verification.tautulli` — `scripts/verify/tautulli.sh`: Kustomization Ready, HelmRelease
Ready, rollout complete, HTTPRoute Accepted, DNS resolves to the gateway VIP, and HTTP 200
on `/status` through the internal gateway.

### 7.5 Coverage deliberately not added

Per D8. Chainsaw media smoke tests assert Kustomization Ready → HelmRelease Ready →
Deployment Available, a strict subset of §7.4. qBittorrent and qbit_manage have smoke tests
for reasons that do not transfer: a VPN dimension, and a UI-less workload whose logs contain
torrent names. Plex, Seerr, Prowlarr, Sonarr, Radarr, Lidarr, and FlareSolverr have none.

## 8. Rollout sequence

### 8.1 PR 1 — staged suspended

Everything lands with `ks.yaml` at `suspend: true`. Because the validators are
activation-aware, that specifically means **no** Gatus endpoint and **no** `widget.*`
annotations yet — a suspended app publishing either creates a permanently-failing probe.

The alert rules **do** ship active in this PR: `media/namespace` and `plex` are already-live
Kustomizations, so `MediaEndpointDown` begins protecting existing services immediately.
Tautulli's PVC rule is inert because Flux does not apply a suspended app.

`mise exec -- just ci` must pass.

### 8.2 Operator gate

```sh
MEDIA_APP_BOOTSTRAP_CONFIRM='bootstrap:media-app:tautulli' \
  mise exec -- just bootstrap media-app tautulli
```

The recipe asserts origin, runs `require_deployed_source` against `origin/main`, refuses
unless suspended in both Git and the cluster, runs `tautulli-validate`, reconciles, resumes,
waits Ready, then runs `tautulli-verify` — re-suspending on any failure while preserving
resources.

Then first-run configuration in the web UI: connect the Plex server, generate the API key,
confirm the library list populates.

### 8.3 Acceptance gates

All three must pass before activation:

1. `mise exec -- just kube tautulli-verify` green.
2. Tautulli shows the Plex server connected with at least one library.
3. **A real playback session appears in Tautulli's history.** This manual check stands in
   for the automated E2E that D8 establishes is infeasible; it is the only gate that proves
   the Plex API path works end to end.

### 8.4 PR 2 — activation

Flip `suspend: false`, add the Gatus endpoint, add the Homepage widget annotations. The
operator runs `homepage-tautulli-secrets` first so the widget has its key.
`MediaEndpointDown` picks up the new endpoint automatically.

### 8.5 Why two PRs

The binding constraint is a **data dependency**, not risk management: the Homepage widget
needs an API key that does not exist until a human logs into Tautulli. PR 2's content
cannot be authored before the app has run.

The `AGENTS.md` risk rationale is weak here — Tautulli is config-only, mounts no shared
claim, and has no VPN, `NET_ADMIN`, or host access, so a failure CrashLoops in isolation.
Flux already covers unattended breakage twice: `install.remediation.retries: 3` with
rollback, and `gotk_resource_info` Kustomization alerting from #154. Staging's remaining
value is that the operator picks the moment and gets automatic re-suspension on failure.

Staging also does **not** prove Tautulli works. `tautulli-verify` is black-box liveness; the
real risks (wrong Plex token, history not recording) are caught only by §8.3 gate 3.

## 9. Documentation

`docs/arr-stack-startup.md` gains a Tautulli section: rollout sequence, first-run
configuration, the acceptance gates, the API-key/Homepage-widget flow, and the Plex-logs
limitation from §4.

Per the standing convention, no "Phase N" notation appears in new text, and any phase
wording on lines this work edits is dropped.

## 10. Risks and known limitations

| Risk | Handling |
|---|---|
| `/status` unverified on this image | Designed against Tautulli's own container healthcheck. If it requires auth, fall back to a TCP probe on 8181 with a comment explaining the downgrade. Confirmed at §8.2 before activation. |
| UID 568 write access to `/config` | Assumed from the `home-operations` convention; `fsGroup: 568` chowns the fresh PVC. Confirmed at rollout, exactly as Seerr's values flagged for its image. |
| Homepage `tautulli` widget field names | Confirmed against the rendered dashboard rather than assumed. |
| Plex Logs viewer will not work | Structural, not fixable: Plex's config claim is `ReadWriteOncePod`. Documented in §9 so it is not rediscovered as a bug. |
| No notification path from Tautulli | Deliberate (D3). If the dashboard later shows real buffering, adding Tautulli as a declaratively-synced ntfy consumer alongside Seerr is a well-motivated follow-up: a `tautulli` identity in `identities.yaml`, a consumer type in `ntfy-identity.sh`, a branch in `ntfy-consumer-sync.sh`, and amending the §G rule. |
| `MediaEndpointDown` widens alerting to all media apps | Intended. Sonarr, Radarr, Lidarr, Prowlarr, Seerr, and FlareSolverr begin alerting on sustained outage. |

## 11. Verify at implementation time

- `/status` returns 200 unauthenticated on `ghcr.io/home-operations/tautulli:2.17.2`.
- The rendered Deployment has `strategy: Recreate` and the PVC is named `tautulli`.
- Homepage's `tautulli` widget accepts `{{HOMEPAGE_VAR_TAUTULLI_API_KEY}}` as `widget.key`.
- `gatus_results_endpoint_success` carries both `name` and `group` labels as matched in §5.2.
- `promtool` is available through the pinned toolchain for `just ci`.

## 12. Definition of done

- Tautulli is live, unsuspended in Git, and `tautulli-verify` passes.
- A real playback session is recorded in Tautulli history.
- The Homepage widget renders and the Gatus endpoint is green.
- `MediaEndpointDown` and both PVC rules are loaded in Prometheus, with promtool tests
  passing in `just ci`.
- `mise exec -- just ci` passes.
- `docs/arr-stack-startup.md` documents the rollout and the Plex-logs limitation.
