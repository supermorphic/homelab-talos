# Refactor `just *-validate` recipes into a shared validation library

## Context

Every offline validator (`cilium-validate`, `flux-validate`, `plex-validate`, …) lives
inline in `kubernetes/mod.just` (1822 lines) as a hand-written bash shebang recipe.
They all follow one shape — existence loop, `rg -qx` wiring check, a block of
`[[ "$(yq -r '…' file)" == 'expected' ]]` assertions, `kustomize build`, `helm template`
render, success `echo` — but the logic is **copy-pasted per recipe** with no shared
helpers, and the assertions are **silent**: a failure prints an unexplained non-zero exit
with no file, query, expected, or actual value.

Two forces make this the right time to fix it:

1. **Phase 12–14 will clone `plex-validate` five more times** (qbittorrent+gluetun,
   prowlarr, sonarr, radarr, overseerr), all sharing ~8 identical policy invariants
   (media namespace, `media-data` claim, `Recreate`, longhorn RWO config, `emptyDir`
   transcode, internal gateway, pinned tag). Cloning brittle bash 5× multiplies the debt.
2. The dissection of `plex-validate` is correct on the diagnostics: silent assertions,
   weak image-tag check (`latest` passes), brittle exact-set `dependsOn`, near-useless
   `suspend` check, and source-only assertions where the rendered result is what matters.

**Decisions taken (user):** full rewrite of all recipes now; extract logic to
`scripts/validate/*.sh` with thin `just` wrappers; add a cross-app `media-validate`
policy check to `just ci`.

**Already in place (do not re-add):**
- `just kube kubeconform` (`kubernetes/mod.just:248`) already does schema validation
  against Kubernetes + the datreeio CRD catalog. The dissection's "add Kubeconform" is
  done at repo scope — **keep it, don't duplicate per app.**
- Every recipe already renders with `helm template`. We extend render coverage, not add it.
- The repo already learned "exact-set aggregate checks are brittle" — `flux-validate`
  uses presence-based checks with an in-code comment. Apply the same lesson to `dependsOn`.
- `conftest`/OPA is intentionally **not** adopted (dissection agrees "not yet"). Deferred.

## Goal / design principles

- **One assertion library, sourced everywhere.** Descriptive failures (file, query,
  expected, actual). Use `yq -e` (mikefarah v4 is pinned) instead of `[[ $(yq…) == … ]]`.
- **Assert the rendered result for behavior-critical policy**, keep source assertions
  only for repo intent that the render can't show (named `existingClaim`, chartRef, wiring).
- **Data-driven media apps**: the shared invariants live in one place; a per-app script
  is a few lines of parameters + app-specific extras.
- **Thin recipes**: `just` stays the interface; bodies move to `scripts/validate/`
  (shellcheck-able, navigable, testable). `kubernetes/mod.just` shrinks dramatically.
- **No behavior regressions**: after the rewrite, `just ci` must pass/fail on exactly
  the same conditions (plus the new, stricter tag check and the new `media-validate`).

## Proposed structure

```
scripts/validate/
├── lib.sh              # sourced by every validator; assertion + render primitives
├── media-app.sh        # parametric validator for one media app (shared invariants)
├── media-policy.sh     # cross-app media-stack invariants (new: media-validate)
├── plex.sh             # media-app.sh + Plex extras (port 32400, /dev/dri, host)
├── qbittorrent.sh      # media-app.sh + Gluetun/NET_ADMIN/kill-switch extras (Phase 12)
├── cilium.sh           # non-media validators, each sourcing lib.sh
├── flux.sh
├── foundation.sh
├── metrics-server.sh
├── storage.sh
├── csi-driver-smb.sh
├── media-storage.sh
├── intel-gpu-plugin.sh
├── monitoring.sh
├── gatus.sh
├── homepage.sh
└── trivy.sh
```

Recipes in `kubernetes/mod.just` collapse to wrappers, e.g.:

```justfile
plex-validate: require-bash
    scripts/validate/plex.sh

media-validate: require-bash
    scripts/validate/media-policy.sh
```

Note the `kube` module sets `working-directory := ".."`, so scripts run from repo root
and take repo-root-relative paths (as the current recipes already assume).

## `scripts/validate/lib.sh` — the API

Primitives (each prints `ERROR: <desc>` + file/query/expected/actual to stderr and
`return 1` on failure; callers `set -euo pipefail`):

- `assert_file <path> [desc]` — required file exists.
- `assert_wired <line> <parent-kustomization>` — replaces the copy-pasted `rg -qx`.
- `assert_yaml <file> <expr> <desc>` — wraps `yq -e "<expr>"`; use for boolean expressions,
  grouped logical assertions, and set/subset checks.
- `assert_yaml_eq <file> <expr> <expected> <desc>` — convenience for the common `== scalar`.
- `assert_yaml_set <file> <expr> <desc>` — value is present, non-null, non-empty.
- `assert_pinned_tag <file> <expr> <desc>` — **fixes the weak tag check**: string,
  non-empty, and not `latest`/`main`/`master`/`stable`/`nightly`.
- `assert_depends_on <ks> <name>...` — **presence/subset**, not exact-set (fixes the
  brittle `dependsOn` and matches the `flux-validate` lesson).
- `assert_sops_encrypted <file>` — SOPS metadata present / `filestatus` encrypted, for the
  encrypted-secret checks in `flux.sh`/`foundation.sh` (never decrypts, per AGENTS.md).
- `assert_no_deprecated_api <path>` — the deprecated-apiVersion guard from `flux-validate`.
- `render_chart <name> <oci-file> <values> <namespace> <out>` — the isolated-Helm-repo +
  `helm template` idiom (replaces the copy-pasted `HELM_REPOSITORY_CONFIG` trick).
- `assert_rendered <render-file> <expr> <desc>` — assert on rendered manifests via `yq -e`.
- `mktemp_cleanup` — the shared `mktemp -d … ; trap 'rm -rf' EXIT` helper.
- `require_bash` — the bash≥4 guard, **defined once here**, removing the duplication in
  `kubernetes/mod.just:303` and `.just/repository.just:549`. (Keep the private
  `require-bash` recipe as a thin gate that sources lib and runs `require_bash`, so the
  `: require-bash` prerequisites and cross-module callers keep working.)

## Per-app media validator: `media-app.sh`

`scripts/validate/media-app.sh <app>` with optional flags (`--host`, `--port`,
`--image-repo`, `--privileged` for the gluetun exception, `--config-size`), encoding the
shared media invariants **once**, asserting on both source and render:

- files exist + `./<app>/ks.yaml` wired into `media/kustomization.yaml`.
- `ks.yaml`: `dependsOn` ⊇ `{media-storage, internal-gateway}` (subset), suspend is
  omitted-or-boolean, chartRef `app-template`/`OCIRepository`.
- `values.yaml`: `controllers.<app>.type: deployment`, `strategy: Recreate`,
  pinned image tag (`assert_pinned_tag`), config PVC `ReadWriteOncePod` on `longhorn`,
  `persistence.media.existingClaim: media-data`, `transcode.type: emptyDir`.
- `httproute.yaml`: parentRef `internal`, `sectionName: https`, host `<app>.lab…`, port.
- render (`render_chart` from `media/namespace/app/ocirepository.yaml`): Deployment
  `strategy.type: Recreate`, config PVC `accessModes: [ReadWriteOncePod]`, and — unless
  `--privileged` — the container has **no** `NET_ADMIN` capability.

`plex.sh` = `media-app.sh plex --port 32400 --host plex.lab.supermorphic.com …` plus Plex
extras (`/dev/dri`, `terminationGracePeriodSeconds`). `qbittorrent.sh` (Phase 12) adds the
Gluetun sidecar assertions (`--privileged`, `NET_ADMIN` present, `/dev/net/tun` CharDevice,
fail-closed `FIREWALL_OUTBOUND_SUBNETS`).

## Cross-app policy: `media-policy.sh` (`just kube media-validate`, added to `ci`)

Stack-wide invariants that no single app owns — built by iterating
`kubernetes/apps/media/*/app`:

- every media app renders into namespace `media` and mounts `existingClaim: media-data`.
- **only qbittorrent/gluetun carries `NET_ADMIN`**; every other media container must not.
- no media HTTPRoute references a public/external gateway (all `parentRefs` → `internal`).
- all media image tags pinned (`assert_pinned_tag` across the set).

Add `just kube media-validate` to `.justfile` `ci` (after the per-app media validators).

## Rewriting all 13 recipes

Each non-media validator (`cilium`, `flux`, `foundation`, `metrics-server`, `storage`,
`csi-driver-smb`, `media-storage`, `intel-gpu-plugin`, `monitoring`, `gatus`, `homepage`,
`trivy`) moves its body verbatim-in-behavior into `scripts/validate/<name>.sh`, sourcing
`lib.sh` and replacing:

- `[[ "$(yq -r …)" == … ]]` → `assert_yaml_eq` / `assert_yaml`.
- the `rg -qx` wiring line → `assert_wired`.
- the mktemp/trap + isolated-Helm idioms → `mktemp_cleanup` / `render_chart`.
- silent existence loops → `assert_file`.

Handle the known divergences explicitly:
- `cilium.sh` currently has **no** `require-bash`; standardize it onto the gate.
- `flux.sh`/`foundation.sh` keep their SOPS-encryption and dependency-graph checks via
  `assert_sops_encrypted` / `assert_depends_on`; `flux.sh` keeps `assert_no_deprecated_api`
  and its presence-based aggregate build check.
- preserve `flux-validate`'s call into `cilium` validation and all existing `dependsOn`
  graph semantics (as subset checks).

The `just ci` recipe list stays the same order; only recipe bodies change (plus the new
`media-validate` line).

## Critical files

- **New:** `scripts/validate/lib.sh`, `media-app.sh`, `media-policy.sh`, and one
  `<name>.sh` per validator.
- **Edit:** `kubernetes/mod.just` — replace 13 recipe bodies with thin wrappers, drop the
  duplicated `require-bash` body (delegate to lib), keep `kubeconform` as-is.
- **Edit:** `.just/repository.just` — drop the duplicated `require-bash` body (delegate to lib).
- **Edit:** `.justfile` — add `just kube media-validate` to `ci`.
- **Reference (reuse, don't duplicate):** `kubernetes/mod.just:248` (`kubeconform`),
  `kubernetes/mod.just:1214` (`plex-validate`, the pattern source),
  `kubernetes/apps/media/plex/**` (the app layout),
  `docs/decisions/2026-08-02-media-stack-architecture.md` (the documented invariants encoded above).

## Out of scope / deferred

- `conftest`/OPA — revisit only if the shared bash lib becomes unwieldy.
- Cluster-dependent `*-verify`/`*-status`/`*-preflight` recipes — untouched; must never
  enter `just ci` (AGENTS.md).
- Do not touch `*.sops.yaml`, the age key, or decrypt anything.

## Verification

1. `mise exec -- just repo lint` — add `shellcheck` to pre-commit (or run
   `shellcheck scripts/validate/*.sh` manually) so the new scripts are linted.
2. **Behavior parity:** run each `just kube <app>-validate` before and after on a clean
   tree — all must still pass. Then deliberately break one invariant in a scratch copy
   (e.g. set a Plex `image.tag: latest`, flip `strategy` to `RollingUpdate`, add
   `NET_ADMIN`) and confirm the validator now fails **with a descriptive message** naming
   the file/query/expected/actual — the core win over today's silent exit.
3. `mise exec -- just ci` — the full contract passes on the branch (needs network egress
   for Helm; no kubeconfig/age key/cluster).
4. Confirm `just kube media-validate` catches a seeded cross-app violation (e.g. a second
   media app granted `NET_ADMIN`, or an HTTPRoute pointed at a public gateway).
5. Open a PR; the GitHub `ci` check (`mise exec -- just ci`) must be green before squash-merge.
