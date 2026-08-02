# Spec Review Response

**Spec:** `docs/decisions/2026-08-01-tautulli.md`
**Review:** `docs/decisions/reviews/2026-08-01-tautulli-review.md`
**Reviewer verdict:** Not ready — one validation contract makes CI fail deterministically, and several requirements admit materially different implementations.
**Independence:** different-client (OpenAI GPT-5.6-sol via Codex; spec written by claude-code)

Preflight passed: the spec digest still matches the version reviewed (`104234d67e1022ac`).
All six findings were verified against their own cited evidence; all six held; all six were
fixed. Nothing was rejected.

## For you to decide

### 1. `/status` behaviour on the pinned image is still UNVERIFIED

The reviewer read current upstream Tautulli source and found `/status` is exposed **without**
`requireAuth()` for an argument-free request, with basic auth disabled for that path. That is
better news than the spec assumed — it suggests authentication will *not* break the health
path. But the reviewer explicitly could not confirm this for the pinned
`ghcr.io/home-operations/tautulli:2.17.2` image.

The spec now handles either outcome (§4.1 fallback, §8.3 gate 2 checks the literal status
code). No decision needed unless you want the image pulled and probed before planning rather
than at rollout.

### 2. Live Gatus metric labels are still UNVERIFIED

`MediaEndpointDown`, both `ProbeMissing` rules, and the §8.5 series check all match on
`group="Media"` and `name="<app>"`. The reviewer confirmed the repo's YAML defines both
fields consistently and that existing rules match them, but did not query the live exported
series. If the runtime labels differ, every rule in §5.2 silently never fires — the exact
false-confidence failure §7.3 exists to prevent.

Worth one live query against Prometheus before the promtool fixtures are written.

### 3. A correction to the brief I gave the reviewer

I wrote that "every sibling app sets resources." The reviewer checked and found qBittorrent
does not. The finding it supported (F4) still holds — most siblings do, and Seerr specifically
does — but the claim as I stated it was too strong.

## Ledger

### F1 — Defect — evidence holds — FIXED

**Verified:** `kubernetes/apps/media/qbittorrent/app/prometheusrule.yaml` exists, and §2
explicitly keeps it out of scope. The §7.2 assertion as written forbade exactly that file.
`mise exec -- just ci` would have failed on every PR the spec describes. This was a
self-contradiction I introduced in the previous code-review round.

**Changed:** §7.2 now specifies the assertion with `qbittorrent` as an explicit, named
single-app allowlist entry — not a wildcard — so a PrometheusRule added to any *other* media
app still fails validation, which is the point of the check. The exception is tied to the §10
follow-up and deleted with it.

### F2 — Defect — evidence holds — FIXED

**Verified:** Kubernetes `httpGet` probes succeed on any status from 200–399. The spec
claimed all three probes asserted "HTTP 200" and that an auth redirect would "simultaneously
break all three probes *and* the Gatus endpoint — four failure surfaces." That is factually
wrong: a 302 leaves all three probes **green**.

**Changed:** §4.1 now states the real semantics and the real failure mode, which is worse
than the one I described — asymmetric disagreement, where kubelet reports healthy while
`/status` no longer means what the design relies on. §8.3 gate 2 now captures the literal
status code with redirects **not** followed, and notes that a passing probe proves nothing
here.

### F3 — Contradiction — evidence holds — FIXED

**Verified:** D5's rationale said "every current and future media endpoint"; §5.2 excludes
`qbittorrent-vpn`, a current `group="Media"` endpoint, and §7.3 requires a test proving the
exclusion. Quotes accurate; conflict real.

**Determinate because** §5.2 states its reason (`QbittorrentVpnDown` already covers it at
`critical`) and D5's "every" gives none — the reasoned side wins.

**Changed:** D5 now carries the exclusion and its reason, and points at §5.2/§5.3. Wording
only; no design change. Also dropped "strictly more coverage," which the exclusion made
false.

### F4 — Ambiguity — evidence holds — FIXED

**Verified:** the spec specified no CPU/memory requests or limits anywhere. D1 says
"structural clone of Seerr"; Seerr sets `25m`/`256Mi`/`1Gi`. Two genuinely different
implementations — `Burstable` vs `BestEffort` QoS.

**Determinate because** Reading 2 contradicts approved decision D1.

**Changed:** §4's property table now states resources explicitly, mirroring Seerr, with a
note that omitting them is not neutral — a `BestEffort` pod is evicted first under node
pressure on a three-node cluster that also transcodes. Marked inherited, not measured.

### F5 — Ambiguity — evidence holds — FIXED

**Verified:** §8.5 named two Prometheus checks; §7.4 said `tautulli-verify` is liveness-only;
§6.1 added no verifier. One reading implements tracked code, the other leaves two
definition-of-done gates as unrecorded UI clicks.

**Determinate because** `AGENTS.md` (quoted in the request's constraints) requires cluster
health checks to run through guarded recipes and to add one where none exists — which rules
out the manual reading.

**Changed:** §8.5 now specifies checks 1 and 2 as steps added to `scripts/verify/tautulli.sh`
in PR 2, reusing the `/api/v1/rules` pattern the reviewer confirmed `verify/monitoring.sh`
already uses. Check 3's visual half stays explicitly manual. §7.4 and §6.1 updated to match.

**Also found while fixing this:** two sections were both numbered `### 8.5`, which made F5's
citation ambiguous. "Why two PRs" renumbered to §8.6. Flagging it because it is an edit the
reviewer did not request.

### F6 — Ambiguity — evidence holds — FIXED

**Verified:** §8.1 listed the runbook as "complete" in PR 1; §8.2 puts "enable web
authentication" in first-run configuration, which happens *between* the PRs; §8.4's PR 2
table omitted `docs/arr-stack-startup.md` entirely. So the mode could not be documented in
either PR as written.

**Determinate because** §8.2 is specific and unambiguous about when auth is enabled.

**Changed:** §8.1 qualifies the runbook as complete except the auth mode; §8.4 adds
`docs/arr-stack-startup.md` (record the mode and the observed `/status` code) and
`scripts/verify/tautulli.sh`, with a note explaining why the runbook deliberately appears in
both tables.
