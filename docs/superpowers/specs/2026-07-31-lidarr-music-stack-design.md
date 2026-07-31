# Lidarr music automation — design

Status: approved design, pending implementation plan.
Date: 2026-07-31.
Branch: `feature/lidarr`.

## 1. Purpose

Add music to the existing media automation stack by deploying Lidarr as a
first-class `*arr` application alongside Prowlarr, Sonarr, and Radarr, and by
extending qBittorrent and qbit_manage to govern music torrents deliberately.

The music library is **greenfield** — there is no existing collection to import or
reconcile. Every convention below is therefore chosen from scratch rather than
inherited.

Target chain:

```text
Prowlarr → Lidarr → qBittorrent (via Gluetun) → /data/downloads/music
        → Lidarr import (hardlink) → /data/media/music
```

## 2. Scope

In scope:

- Lidarr Flux application (`kubernetes/apps/media/lidarr/`).
- Shared `*arr` tooling: validation, verification, bootstrap recipe, test catalog.
- qBittorrent `music` category (documented operator step).
- qbit_manage dedicated music share-limit group, plus a two-layer restructure of
  the share-limits validation.
- Homepage widget (secret recipe, Secret, env var, validation) and Gatus endpoint.
- Startup and qbit_manage documentation.

Out of scope (deliberately deferred, may become separate work):

- Creating the Plex Music library.
- Plexamp client setup, CarPlay, Sonos.
- A functional end-to-end music download test.
- Chainsaw smoke coverage for Lidarr (see §9).

## 3. Decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | Deploy Lidarr as a structural clone of Radarr | The `*arr` pattern in this repo is uniform; divergence would be unjustified. |
| D2 | Pin `ghcr.io/home-operations/lidarr:3.1.2.4902` | Greenfield has no config DB to migrate, so Radarr's cautious major-version staging buys nothing. No Renovate in this repo — pins are manual. |
| D3 | Quality target: FLAC/lossless preferred, lossy fallback | Best playback quality without the library gaps a lossless-only profile creates. |
| D4 | Dedicated qbit_manage `music` share-limit group | Music has a genuinely different seeding profile from movies/TV; a separate group makes the policy intentional. See §7. |
| D5 | Restructure share-limits validation into two layers | A third group turns the existing pairwise priority assertion into a safety hole. See §7.3. |
| D6 | Table-driven refactor of `scripts/validate/arr.sh` | A fourth near-identical `if` block is the signal to convert branching into data. |
| D7 | Plex-documented naming, no release year in album folders | Taken from Plex's own specification rather than convention. See §8. |
| D8 | Drop `Phase N` notation from every line this work edits | Phase numbers were initial-rollout scaffolding; Lidarr belongs to no phase. |
| D9 | No Chainsaw smoke test for Lidarr | Its three siblings have none; inconsistent coverage adds no safety. |

## 4. Architecture

Lidarr runs in the `media` namespace as a single-replica Deployment with
`strategy: Recreate` over a ReadWriteOnce Longhorn config PVC (single-writer
SQLite). It mounts the shared SMB PVC `media-data` at `/data`, so imports hardlink
from `/data/downloads/music` into `/data/media/music` on one filesystem rather than
copying.

Lidarr does **not** route through Gluetun. Like Sonarr and Radarr it talks to
Prowlarr and the qBittorrent API over cluster DNS; only qBittorrent's own traffic
egresses through the VPN.

Key parameters:

| Property | Value |
|---|---|
| Namespace | `media` |
| Service port | `8686` |
| Hostname | `lidarr.lab.supermorphic.com` |
| Health endpoint | `/ping` (unauthenticated, returns 200) |
| Config PVC | 5Gi, `longhorn`, RWO, `helm.sh/resource-policy: keep`, at `/config` |
| Media mount | `existingClaim: media-data` at `/data` |
| Pod security | `runAsUser/Group/fsGroup: 568`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]` |
| Resources | requests 25m CPU / 256Mi; limit 1Gi memory, no CPU limit |
| Flux deps | `media-storage`, `internal-gateway` |

`/data/media/music` does not exist yet. The SMB mount is `uid=568,gid=568,
dir_mode=0775` and Lidarr runs as 568, so Lidarr creates the directory itself when
the root folder is set in the UI. No manual NAS step.

## 5. Rollout sequence

Two PRs with an operator gate between them. This shape is forced by two existing
constraints, not chosen:

- `scripts/validate/arr.sh` refuses a Gatus endpoint for a suspended app and
  requires one for an active app.
- `scripts/validate/homepage.sh` requires each widget's SOPS Secret to exist, and
  that Secret needs an API key that only exists after Lidarr's first run.

### PR 1 — staged, suspended

| File | Change |
|---|---|
| `kubernetes/apps/media/lidarr/ks.yaml` | New. `suspend: true`, `dependsOn: [media-storage, internal-gateway]` |
| `kubernetes/apps/media/lidarr/app/{helmrelease,values,httproute,kustomization}.yaml` | New, per §4 and §6 |
| `kubernetes/apps/media/kustomization.yaml` | Add `- ./lidarr/ks.yaml` |
| `scripts/validate/arr.sh` | Table-driven refactor + `lidarr` row (§6.1); drop phase wording from the "Missing … source" error and the final success message |
| `scripts/verify/arr.sh` | Add `lidarr` to the `case` allowlist and both usage strings |
| `.just/bootstrap.just` | Add `lidarr` to the allowlist; confirm string → `bootstrap:arr:<app>`; drop phase wording from the recipe comment, the cleanup message, and the recommended-order note |
| `.just/repository.just` | New `homepage-lidarr-secrets` recipe |
| `kubernetes/mod.just` | Drop phase wording from the `arr-validate` / `arr-verify` comments |
| `tests/catalog.yaml` | `verification.lidarr` entry + media suite membership |
| `docs/arr-stack-startup.md` | Lidarr sections, `music` category, naming, caveats (§8) |

Not in PR 1: the Gatus endpoint, the Homepage Secret, its env var, and its
validation assertions.

### Operator gate

1. `mise exec -- just bootstrap arr lidarr` (requires `ARR_BOOTSTRAP_CONFIRM='bootstrap:arr:lidarr'`).
2. First-run configuration per the new startup documentation.
3. `mise exec -- just repo homepage-lidarr-secrets` with `LIDARR_API_KEY` and
   `HOMEPAGE_LIDARR_SECRETS_CONFIRM='write:monitoring:homepage-lidarr:sops'`.

### PR 2 — activation

| File | Change |
|---|---|
| `kubernetes/apps/media/lidarr/ks.yaml` | `suspend: false` |
| `kubernetes/apps/monitoring/gatus/app/values.yaml` | `lidarr` endpoint, group `Media`, `/ping`, 1m, `[STATUS] == 200` |
| `kubernetes/apps/monitoring/homepage/app/homepage-lidarr.sops.yaml` | Operator-generated Secret |
| `kubernetes/apps/monitoring/homepage/app/kustomization.yaml` | Add the Secret to `resources` |
| `kubernetes/apps/monitoring/homepage/app/deployment.yaml` | `HOMEPAGE_VAR_LIDARR_API_KEY`, `optional: true` |
| `scripts/validate/homepage.sh` | Lidarr Secret + env var assertions |
| `kubernetes/apps/media/qbit-manage/app/config.yml` | `music` share-limit group (§7.1) |
| `scripts/validate/qbit-manage*.sh` | Two-layer restructure (§7.3) |
| `docs/qbit-manage.md` | Music group, flow diagram, safety-invariant section |

The `sops-hash` pod annotation is keyed only to `homepage-ntfy.sops.yaml`, so a new
Secret causes no hash churn.

## 6. Lidarr application

`values.yaml` mirrors Radarr's with the image, port, and controller name changed.
Probes are `/ping` on 8686 with Radarr's periods and thresholds (readiness 10s×3,
liveness 30s×5, startup 5s×30).

The HTTPRoute mirrors Radarr's with Homepage annotations:

```yaml
gethomepage.dev/widget.type: "lidarr"
gethomepage.dev/widget.url: "http://lidarr.media.svc.cluster.local:8686"
gethomepage.dev/widget.key: "{{HOMEPAGE_VAR_LIDARR_API_KEY}}"
gethomepage.dev/icon: "lidarr.svg"
gethomepage.dev/group: "Media"
gethomepage.dev/description: "Music"
```

### 6.1 `scripts/validate/arr.sh` refactor

Replace the `for app in prowlarr sonarr radarr` loop and its three per-app `if`
blocks with a record array holding only what cannot be derived from the manifest
under test:

```bash
# app|port|mounts_data|deps
arr_apps=(
  "prowlarr|9696|no|internal-gateway,media"
  "sonarr|8989|yes|internal-gateway,media-storage"
  "radarr|7878|yes|internal-gateway,media-storage"
  "lidarr|8686|yes|internal-gateway,media-storage"
)
```

Widget *type* is deliberately absent: it equals the app name for all four, so the
loop derives it. The `HOMEPAGE_VAR_*` name is built with `${app^^}` — the repo
requires bash >= 5 (`scripts/lib/common.sh:5`), so case expansion is available.

New assertion enabled by the table: `service.app.ports.http.port` and the
HTTPRoute's `backendRefs[0].port` must both equal `$port`. Today only the backend
*name* is checked, so a wrong-port route passes CI. This is new coverage on three
live apps — verify all three already satisfy it before committing, and drop the
assertion if any do not.

## 7. qbit_manage music policy

### 7.1 The group

```yaml
  music:
    priority: 50
    categories:
      - music
    exclude_any_tags:
      - tracker-private
      - tracker-czteam
    max_ratio: 2.0
    min_seeding_time: 7d
    max_seeding_time: 30d
    share_limit_action: Stop
    cleanup: true
```

`public` remains `[movies, tv]` and is not edited, so the existing
`'["movies","tv"]'` assertion needs no change.

Behaviour: seed at least 7 days always; stop once both ratio 2.0 and 7 days are
met; stop unconditionally at 30 days; then cleanup moves the download-side data to
the 7-day recycle bin while the `/data/media/music` hardlink survives.

Two properties make this correct rather than merely plausible:

- **CZTeam music is protected twice over, independently.** Per the qbit_manage
  matching rules ([Config-Setup wiki](https://github.com/StuffAnThings/qbit_manage/wiki/Config-Setup)):
  groups are evaluated in priority order, lowest
  number first; a torrent matches exactly one group; and an *excluded* torrent falls
  through to be evaluated against the remaining groups. A CZTeam music torrent
  therefore hits `czteam` (10) first and matches on `include_all_tags`, never
  reaching the music group. Were the priorities ever inverted, `music`'s
  `exclude_any_tags` would exclude it and it would fall through to `czteam` anyway.
  Neither mechanism is the sole protection — see §7.3 for why both are still worth
  asserting. `priority: 50` differs from public's 100 only to keep resolution
  deterministic; the two never compete, since their categories are disjoint.
- **The 7-day floor behaves as intended.** `min_seeding_time` is a hard floor that
  requires a positive `max_ratio`; 2.0 satisfies it. Reaching ratio 2.0 early does
  not stop the torrent — qbit_manage clears the limit and resumes until day 7.

### 7.2 Why longer seeding is nearly free

Lidarr imports by hardlink, so the download-side file and the library file are the
same inode. Retaining a music torrent for 30 days retains a second *name* for bytes
the library already holds, not a second copy; cleanup decrements the link count. The
marginal storage cost of the longer window is therefore approximately zero. The real
cost is qBittorrent tracking more active torrents.

### 7.3 Two-layer validation restructure

Current state (verified):

| Group | Policy numbers | Safety gates |
|---|---|---|
| `public` | `qbit-manage.sh:108-114` | `qbit-manage-policy.sh:90-104` |
| `czteam` | `qbit-manage-policy.sh:127-147` | `qbit-manage-policy.sh:108-124` |

`public` is the only group split across two files; the split is an artifact of build
order, not a principle. Adding a music block to each file would propagate it.

The change that makes this necessary rather than cosmetic:
`qbit-manage-policy.sh:114-119` asserts czteam's precedence **pairwise** against
`public`. With two groups, "czteam < public" and "czteam is highest precedence" are
the same statement. With three or more they diverge, and nothing then checks czteam
against the newer groups.

The two set-wide invariants below are kept because they catch **different** failure
classes. Neither subsumes the other:

| Failure | Priority invariant | Exclusion invariant |
|---|---|---|
| A future group at priority < 10 with `cleanup: false` but a finite `max_seeding_time` stops a CZTeam torrent early → hit-and-run at the tracker | catches it | misses it — invariant 2 only constrains `cleanup: true` groups |
| A future `cleanup: true` group without exclusions matches a *generic* private torrent (`tracker-private` only, no `tracker-czteam`, so `czteam` never applies) → private torrent removed | misses it | catches it |

Note what is deliberately *not* claimed: raising a group above czteam does not by
itself expose a CZTeam torrent to that group's cleanup, because the exclusion tags
would cause fall-through. The priority invariant earns its place through the first
row above, not through a cleanup scenario.

Target structure, consolidated into `qbit-manage-policy.sh` so one file owns the
share-limits model:

**Layer 1 — per-group expected values.** One helper invoked three times (`public`,
`music`, `czteam`) with that group's ratio, min/max seed time, action, and cleanup
flag. Collapses three near-duplicate blocks into three call sites. The `public`
block moves out of `qbit-manage.sh`.

**Layer 2 — set-wide invariants**, computed across all groups with `yq` and no
hardcoded group names:

1. `czteam.priority` is the strict minimum across all groups.
2. Every group with `cleanup: true` excludes both `tracker-private` and
   `tracker-czteam`.
3. Priorities are unique.

Invariant 2 is the important generalisation: the rule is not "public excludes
private tags" but "no cleanup-enabled group can ever touch a private torrent," so a
future `books` or `audiobooks` group cannot be added without the gate.

Optional, not required: assert category lists are pairwise disjoint. Priority
uniqueness already makes group resolution deterministic.

**Gotcha:** `qbit-manage-policy.sh:127-131` accepts both `'2'` and `'2.0'` for
czteam's ratio, indicating yq scalar normalisation is not dependable here. Music's
`max_ratio: 2.0` needs the same dual-accept or it will fail depending on yq version.

## 8. Library naming convention

Taken from Plex's specification (support.plex.tv article 200265296, last modified
22 May 2026), not from convention:

```text
Music/ArtistName/AlbumName/TrackNumber - TrackName.ext
```

Target output:

```text
/data/media/music/{Artist}/{Album}/{Disc}{Track:00} - {Title}.{ext}
```

Three deliberate deviations from Lidarr's defaults, each documented with its reason:

1. **No release year in the album folder.** Plex's examples are bare album names
   (`/The Wall`, `/Wish You Were Here`). The widespread `Album (Year)` convention is
   usually tolerated because Plex matches on embedded tags and sonic fingerprinting
   rather than folder names — but greenfield means there is no reason to deviate from
   the documented spec.
2. **Multi-disc uses a prepended disc number in a flat album folder**, not disc
   subfolders: `101 - Track.ext`, `201 - Track.ext`. Plex states this explicitly and
   warns that other structures degrade the experience. Correct disc numbers must also
   be present in the embedded tags.
3. **Compilations go under a literal `Various Artists` artist folder**, with the
   embedded `Album Artist` tag set to `Various Artists` and `Artist` set to the
   performing artist. Getting this wrong scatters compilation tracks under individual
   artists.

Embedded tags are load-bearing for Plex matching, so Lidarr must not be configured
to rewrite tags broadly during initial rollout, and `Prefer local metadata` should
not be enabled by default.

## 9. Testing and verification

The `arr.sh` and qbit_manage refactors both touch validation that currently gates CI
for live applications, so the safety argument is **differential**, not "CI passes":

1. Capture `mise exec -- just kube arr-validate` output on `main`.
2. Apply the refactor **without** the Lidarr row; re-run. Output must be identical —
   the same three `OK` lines. This proves the refactor is behaviour-preserving
   independently of whether Lidarr is correct.
3. Add the Lidarr row; re-run. Expect the same three lines plus `lidarr … OK`.
4. Repeat the same three-step procedure for `just kube qbit-manage-validate` around
   the two-layer restructure, adding the music group only after the restructure is
   proven inert.
5. `mise exec -- just ci` for the full gate.

Live acceptance is `mise exec -- just kube arr-verify lidarr` (Kustomization and
HelmRelease Ready, rollout, HTTPRoute Accepted, DNS, `/ping` through the internal
gateway), registered as `verification.lidarr` in `tests/catalog.yaml`.

No Chainsaw smoke test: `tests/chainsaw/smoke/media/` covers only `qbittorrent` and
`qbit-manage`; Prowlarr, Sonarr, and Radarr have none. If Chainsaw coverage for the
`*arr` apps is wanted, it should be added for all four at once as separate work.

## 10. Risks and known limitations

- **Lidarr's external metadata proxy.** Lidarr depends on `api.lidarr.audio`, a
  MusicBrainz mirror with a history of outages. During one, `/ping` returns 200 —
  the pod stays Ready and Gatus stays green — while artist and album adds fail.
  No health check can detect this; it is documented in the startup guide instead.
- **Breaking change to a documented operator command.** The `bootstrap arr` confirm
  string changes from `bootstrap:phase13:<app>` to `bootstrap:arr:<app>` for all four
  apps. Prowlarr, Sonarr, and Radarr are already live, so this only affects Lidarr or
  a future re-bootstrap, but it must be called out in the PR description.
- **Memory limit is a guess.** 1Gi matches the siblings. Lidarr is the most
  memory-hungry `*arr` during metadata refresh, but that scales with library size and
  this one starts empty. If it OOMs during a large import, raising the limit is a
  one-line follow-up rather than something to pre-inflate on speculation.
- **Hardlink survival depends on a first-run setting.** The `/data/media/music`
  file survives cleanup only if Lidarr is configured to hardlink rather than copy.
  That is a UI setting, not a manifest guarantee, so it is both a documented step and
  an item to confirm during the first real import.

## 11. Verify at implementation time

Items deliberately not asserted in this design because they must be read from the
running system or a current source:

- The newest `ghcr.io/home-operations/lidarr` tag (3.1.2.4902 at design time).
- Lidarr 3.1.2's exact naming token syntax, read off the deployed UI — the target
  *output* in §8 is authoritative, the tokens that produce it are not yet verified.
- Whether Lidarr defaults to disc subfolders for multi-disc releases (believed yes,
  unverified), which determines how much §8's deviation 2 needs to change.
- That Prowlarr, Sonarr, and Radarr already satisfy the new port assertion in §6.1.

## 12. Definition of done

- Lidarr reconciles through Flux, unsuspended and durable in Git.
- Config survives pod recreation on the retained Longhorn PVC.
- `mise exec -- just ci` passes, including the refactored `arr.sh` and the
  restructured qbit_manage validation.
- `mise exec -- just kube arr-verify lidarr` passes.
- Gatus shows `lidarr` green; the Homepage widget renders with no committed
  plaintext key.
- qBittorrent has a `music` category at `/data/downloads/music`; qbit_manage applies
  the music group, and CZTeam music still selects the czteam group.
- A real import lands in `/data/media/music` with the §8 structure and a link count
  of 2.
- Startup and qbit_manage documentation cover every non-declarative step.
