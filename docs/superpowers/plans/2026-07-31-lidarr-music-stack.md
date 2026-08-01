# Lidarr Music Stack Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy Lidarr as a durable, first-class `*arr` application and extend the surrounding download, seeding, monitoring, Homepage, validation, and operator workflows for a greenfield music library.

**Architecture:** Lidarr follows the existing Radarr app-template pattern: a single `Recreate` Deployment, retained Longhorn config PVC, shared `media-data` PVC at `/data`, internal Gateway HTTPRoute, and first-run state persisted outside Git. Delivery is deliberately split into a suspended PR and an activation PR, with an operator-run first import and SOPS Secret creation between them; qbit_manage gains a category-specific music policy only in the activation PR.

**Tech Stack:** Flux Kustomizations and HelmReleases, bjw-s app-template, Kubernetes Gateway API, Bash 5, `yq`, `kustomize`, `helm`, SOPS/age, qBittorrent, qbit_manage, Homepage, Gatus, `just`, and the repository's pinned `mise` toolchain.

## Global Constraints

- Work only on `feature/lidarr`; never commit, push, merge, or enable auto-merge on `main`.
- Run repository workflows with `mise exec -- just ...`; run pinned ad hoc tools with `mise exec -- ...`.
- Use guarded `just` recipes for every live-cluster check or mutation. The operator, not the implementation agent, runs mutating bootstrap and Secret recipes.
- Deliver exactly two PRs with the operator gate below between them. PR 1 stages Lidarr with `spec.suspend: true`; PR 2 persists `spec.suspend: false`.
- Pin `ghcr.io/home-operations/lidarr:3.1.2.4902`. At implementation time, confirm this tag still exists and record whether a newer stable tag exists; changing the approved pin requires an explicit design update.
- Lidarr runs in namespace `media` on port `8686`, hostname `lidarr.lab.supermorphic.com`, with unauthenticated health endpoint `/ping`.
- Lidarr depends on `media-storage` and `internal-gateway`; it does not share Gluetun's network namespace.
- Use a single-replica Deployment with `strategy: Recreate` because `/config` is a `ReadWriteOnce` SQLite volume.
- The config PVC is `5Gi`, `longhorn`, `ReadWriteOnce`, retained with `helm.sh/resource-policy: keep`, and mounted at `/config`.
- Mount existing claim `media-data` at `/data`; downloads use `/data/downloads/music` and imports use `/data/media/music` on the same filesystem.
- Run Lidarr with `runAsUser`, `runAsGroup`, and `fsGroup` `568`; set `allowPrivilegeEscalation: false` and drop `ALL` capabilities.
- Request `25m` CPU and `256Mi` memory; limit memory to `1Gi` and set no CPU limit.
- Use `/ping` probes with readiness `periodSeconds: 10`, `failureThreshold: 3`; liveness `30` and `5`; startup `5` and `30`.
- Prefer FLAC/lossless while retaining a lossy fallback quality profile.
- The authoritative library output is `/data/media/music/{Artist}/{Album}/{Disc}{Track:00} - {Title}.{ext}`: no album release year, flat multi-disc numbering such as `101`/`201`, and compilation artist folder `Various Artists`.
- Keep **Use Hardlinks instead of Copy** enabled and **Write Metadata to Audio Files** disabled. Rewriting tags on an active hardlink can invalidate the seeding torrent.
- PR 1 has no Lidarr Gatus endpoint, no `widget.*` HTTPRoute annotations, and no Homepage Lidarr Secret or env var. PR 2 adds all of them together.
- Never decrypt or hand-edit a SOPS file. The operator creates `homepage-lidarr.sops.yaml` only through `mise exec -- just repo homepage-lidarr-secrets` with `LIDARR_API_KEY` and `HOMEPAGE_LIDARR_SECRETS_CONFIRM='write:monitoring:homepage-lidarr:sops'`.
- qbit_manage's music group is priority `50`, category `music`, excludes both private tags, ratio `2.0`, minimum seed `7d`, maximum seed `30d`, action `Stop`, and `cleanup: true`.
- qbit_manage validation has two layers: exact values for `public`, `music`, and `czteam`, followed by name-independent invariants for CZTeam's strict-minimum priority, private-tag exclusions on every cleanup group, and unique priorities.
- Every line changed by this work must avoid initial-rollout `Phase N` wording.
- Do not add a Plex Music library, Plexamp setup, an automated functional music-download test, or Lidarr Chainsaw smoke coverage.

## Delivery Boundaries and File Map

PR 1 owns the suspended application, shared `*arr` tooling, Secret-generation recipe, catalog registration, and first-run documentation:

- Create `kubernetes/apps/media/lidarr/ks.yaml` — suspended Flux child and dependency graph.
- Create `kubernetes/apps/media/lidarr/app/helmrelease.yaml` — app-template HelmRelease.
- Create `kubernetes/apps/media/lidarr/app/values.yaml` — Lidarr workload, probes, security, resources, and storage.
- Create `kubernetes/apps/media/lidarr/app/httproute.yaml` — internal route and non-widget Homepage discovery metadata.
- Create `kubernetes/apps/media/lidarr/app/kustomization.yaml` — app resources and generated values ConfigMap.
- Modify `kubernetes/apps/media/kustomization.yaml` — register Lidarr.
- Modify `scripts/validate/arr.sh` — table-driven validation, activation-aware widgets, and service/route port checks.
- Modify `scripts/verify/arr.sh` — allow and document `lidarr`.
- Modify `.just/bootstrap.just` — guarded Lidarr rollout and source guard expansion.
- Modify `.just/repository.just` — operator-only Homepage Lidarr SOPS recipe.
- Modify `kubernetes/mod.just` — current `*arr` recipe descriptions.
- Modify `tests/catalog.yaml` — `verification.lidarr` and verification-suite membership.
- Modify `docs/arr-stack-startup.md` — music category, Lidarr setup, naming, safety caveats, and acceptance gate.

PR 2 owns activation, monitoring, Homepage, and the qbit_manage policy:

- Modify `kubernetes/apps/media/lidarr/ks.yaml` — persist activation.
- Modify `kubernetes/apps/media/lidarr/app/httproute.yaml` — add the complete Lidarr widget contract.
- Modify `kubernetes/apps/monitoring/gatus/app/values.yaml` — add the black-box `/ping` endpoint.
- Create `kubernetes/apps/monitoring/homepage/app/homepage-lidarr.sops.yaml` — operator-generated encrypted API key.
- Modify `kubernetes/apps/monitoring/homepage/app/kustomization.yaml` — reconcile the new Secret.
- Modify `kubernetes/apps/monitoring/homepage/app/deployment.yaml` — expose the optional Lidarr key variable.
- Modify `scripts/validate/homepage.sh` — validate the encrypted Secret and env reference.
- Modify `scripts/validate/qbit-manage.sh` — remove ownership of public share-limit numbers.
- Modify `scripts/validate/qbit-manage-policy.sh` — own the complete share-limit model and its invariants.
- Modify `scripts/test/qbit-manage-policy-validator-test.sh` — prove exact values and future-group safety failures.
- Modify `kubernetes/apps/media/qbit-manage/app/config.yml` — add the music group.
- Modify `kubernetes/apps/media/qbit-manage/app/values.yaml` — stamp the changed config blob hash.
- Modify `docs/qbit-manage.md` — document music flow, behavior, and generalized safety invariants.

---

## PR 1 — Suspended Lidarr

### Task 1: Rebase Safely and Refactor `arr.sh` Without Lidarr

**Files:**
- Modify: `scripts/validate/arr.sh:10-81`

**Interfaces:**
- Consumes: Existing Prowlarr, Sonarr, and Radarr manifests plus `kubernetes/apps/monitoring/gatus/app/values.yaml`.
- Produces: `arr_apps` records shaped as `app|port|mounts_data|deps`; activation-aware Gatus/widget validation; exact values/route port validation.

- [ ] **Step 1: Bring the clean feature branch onto the current production boundary**

Run:

```bash
mise exec -- git status --short --branch
mise exec -- git fetch origin
mise exec -- git rebase origin/main
```

Expected: the branch is `feature/lidarr`, the worktree is clean before the rebase, and the three design commits remain above the current `origin/main`. If unrelated user changes appear, stop and preserve them rather than rebasing through them.

- [ ] **Step 2: Capture the production-equivalent `*arr` baseline before editing**

Run:

```bash
arr_baseline_dir="$(mktemp -d /tmp/lidarr-arr-baseline.XXXXXX)"
mise exec -- just kube arr-validate >"$arr_baseline_dir/before.txt"
mise exec -- rg '^  (prowlarr|sonarr|radarr) .* OK$' \
  "$arr_baseline_dir/before.txt" >"$arr_baseline_dir/before.ok"
mise exec -- rg '^  (prowlarr|sonarr|radarr) .* OK$' "$arr_baseline_dir/before.txt"
```

Expected: exit `0` and one `OK` line for each of Prowlarr, Sonarr, and Radarr. Keep `arr_baseline_dir` in the shell for Step 5.

- [ ] **Step 3: Replace branches with the three-row record table**

Use this exact record contract at the top of the validator:

```bash
arr_apps=(
  "prowlarr|9696|no|internal-gateway,media"
  "sonarr|8989|yes|internal-gateway,media-storage"
  "radarr|7878|yes|internal-gateway,media-storage"
)

for record in "${arr_apps[@]}"; do
  IFS='|' read -r app port mounts_data expected_deps <<<"$record"
```

Replace the Prowlarr-specific dependency and data-mount branches with comparisons against `expected_deps` and `mounts_data`. Change the missing-file error to `Missing *arr source: $f`. Retain every existing security, PVC, render, hostname, Gateway, image repository, and pinned-tag assertion.

- [ ] **Step 4: Add derived port and activation-aware widget assertions**

Immediately after the existing HTTPRoute backend-name check, add:

```bash
[[ "$(yq -r '.service.app.ports.http.port' "$values")" == "$port" ]] || {
  echo "$app service port must be $port." >&2
  exit 1
}
[[ "$(yq -r '.spec.rules[0].backendRefs[0].port' "$route")" == "$port" ]] || {
  echo "$app HTTPRoute backend port must be $port." >&2
  exit 1
}
```

Replace the three widget `if` blocks with:

```bash
widget_count="$(yq -r \
  '[(.metadata.annotations // {}) | keys[] | select(startswith("gethomepage.dev/widget."))] | length' \
  "$route")"
if [[ "$suspend_state" == 'false' ]]; then
  [[ "$(yq -r '.metadata.annotations."gethomepage.dev/widget.type"' "$route")" == "$app" ]]
  [[ "$(yq -r '.metadata.annotations."gethomepage.dev/widget.url"' "$route")" == \
    "http://$app.media.svc.cluster.local:$port" ]]
  widget_key="HOMEPAGE_VAR_${app^^}_API_KEY"
  [[ "$(yq -r '.metadata.annotations."gethomepage.dev/widget.key"' "$route")" == \
    "{{${widget_key}}}" ]]
else
  [[ "$widget_count" == '0' ]] || {
    echo "Suspended $app must not publish widget.* annotations." >&2
    exit 1
  }
fi
```

End with a phase-free summary that names the three current apps and mentions activation-aware Gatus and Homepage widgets.

- [ ] **Step 5: Prove the refactor is behavior-preserving**

Run:

```bash
mise exec -- just kube arr-validate >"$arr_baseline_dir/after-refactor.txt"
mise exec -- rg '^  (prowlarr|sonarr|radarr) .* OK$' \
  "$arr_baseline_dir/after-refactor.txt" >"$arr_baseline_dir/after-refactor.ok"
mise exec -- git diff --no-index --exit-code \
  "$arr_baseline_dir/before.ok" "$arr_baseline_dir/after-refactor.ok"
```

Expected: validation exits `0` and the `OK` files are identical. If any live app fails the new service/route port assertion, remove that assertion as the approved design directs; do not change a live app merely to make the refactor pass.

- [ ] **Step 6: Commit the independently proven refactor**

```bash
mise exec -- git add scripts/validate/arr.sh
mise exec -- git commit -m "refactor(validation): make arr checks table driven"
```

### Task 2: Add the Suspended Lidarr Flux Application

**Files:**
- Create: `kubernetes/apps/media/lidarr/ks.yaml`
- Create: `kubernetes/apps/media/lidarr/app/helmrelease.yaml`
- Create: `kubernetes/apps/media/lidarr/app/values.yaml`
- Create: `kubernetes/apps/media/lidarr/app/httproute.yaml`
- Create: `kubernetes/apps/media/lidarr/app/kustomization.yaml`
- Modify: `kubernetes/apps/media/kustomization.yaml:11-14`
- Modify: `scripts/validate/arr.sh:10-14`

**Interfaces:**
- Consumes: The `arr_apps` record contract from Task 1 and the shared `app-template` OCIRepository.
- Produces: Flux Kustomization `lidarr`, HelmRelease/Deployment/Service `lidarr`, internal HTTPRoute `lidarr`, and a fourth validator row `lidarr|8686|yes|internal-gateway,media-storage`.

- [ ] **Step 1: Confirm the approved image tag exists**

Run this read-only query with the pinned GitHub CLI:

```bash
mise exec -- gh api --paginate \
  /orgs/home-operations/packages/container/lidarr/versions \
  --jq '.[] | .metadata.container.tags[] | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$"))'
```

Expected: `3.1.2.4902` appears. Note any newer stable tag in the PR description, but keep the approved pin unless the design is explicitly revised.

- [ ] **Step 2: Add the Lidarr row first and observe the missing-source failure**

Append this record to `arr_apps`:

```bash
  "lidarr|8686|yes|internal-gateway,media-storage"
```

Run:

```bash
mise exec -- just kube arr-validate
```

Expected: FAIL with `Missing *arr source: kubernetes/apps/media/lidarr/ks.yaml`.

- [ ] **Step 3: Create the suspended Flux Kustomization**

Create `kubernetes/apps/media/lidarr/ks.yaml` with:

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kustomize.toolkit.fluxcd.io/kustomization_v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: lidarr
  namespace: flux-system
spec:
  dependsOn:
    - name: media-storage
    - name: internal-gateway
  interval: 1h
  path: ./kubernetes/apps/media/lidarr/app
  prune: true
  retryInterval: 1m
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
  suspend: true
  timeout: 10m
  wait: true
```

- [ ] **Step 4: Create the HelmRelease and app kustomization**

Create `kubernetes/apps/media/lidarr/app/helmrelease.yaml` with:

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/helm.toolkit.fluxcd.io/helmrelease_v2.json
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: lidarr
  namespace: media
spec:
  chartRef:
    kind: OCIRepository
    name: app-template
  driftDetection:
    mode: enabled
  install:
    remediation:
      retries: 3
  interval: 1h
  releaseName: lidarr
  timeout: 10m
  upgrade:
    cleanupOnFail: true
    remediation:
      retries: 3
      strategy: rollback
  valuesFrom:
    - kind: ConfigMap
      name: lidarr-values
      valuesKey: values.yaml
```

Create `kubernetes/apps/media/lidarr/app/kustomization.yaml` with:

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./helmrelease.yaml
  - ./httproute.yaml
configMapGenerator:
  - name: lidarr-values
    namespace: media
    files:
      - values.yaml=values.yaml
generatorOptions:
  disableNameSuffixHash: true
  labels:
    reconcile.fluxcd.io/watch: Enabled
```

- [ ] **Step 5: Create the Lidarr workload values**

Create `kubernetes/apps/media/lidarr/app/values.yaml` with this shape and exact values:

```yaml
# Lidarr (music) via the bjw-s app-template chart. Single replica, Recreate on a retained
# Longhorn RWO config volume. The shared media-data PVC is mounted at /data so imports
# hardlink from /data/downloads/music into /data/media/music on one filesystem.
controllers:
  lidarr:
    type: deployment
    strategy: Recreate
    pod:
      securityContext:
        runAsUser: 568
        runAsGroup: 568
        fsGroup: 568
        fsGroupChangePolicy: OnRootMismatch
    containers:
      app:
        image:
          repository: ghcr.io/home-operations/lidarr
          tag: 3.1.2.4902
        env:
          TZ: America/Denver
        resources:
          requests:
            cpu: 25m
            memory: 256Mi
          limits:
            memory: 1Gi
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
        probes:
          readiness:
            enabled: true
            custom: true
            spec:
              httpGet:
                path: /ping
                port: 8686
              periodSeconds: 10
              failureThreshold: 3
          liveness:
            enabled: true
            custom: true
            spec:
              httpGet:
                path: /ping
                port: 8686
              periodSeconds: 30
              failureThreshold: 5
          startup:
            enabled: true
            custom: true
            spec:
              httpGet:
                path: /ping
                port: 8686
              periodSeconds: 5
              failureThreshold: 30
service:
  app:
    controller: lidarr
    ports:
      http:
        port: 8686
persistence:
  config:
    type: persistentVolumeClaim
    accessMode: ReadWriteOnce
    size: 5Gi
    storageClass: longhorn
    annotations:
      helm.sh/resource-policy: keep
    globalMounts:
      - path: /config
  data:
    type: persistentVolumeClaim
    existingClaim: media-data
    globalMounts:
      - path: /data
```

- [ ] **Step 6: Create only the non-widget HTTPRoute metadata**

Create `kubernetes/apps/media/lidarr/app/httproute.yaml` with:

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/gateway.networking.k8s.io/httproute_v1.json
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: lidarr
  namespace: media
  annotations:
    external-dns.k8s.io/audience: internal
    gethomepage.dev/enabled: "true"
    gethomepage.dev/name: "Lidarr"
    gethomepage.dev/description: "Music"
    gethomepage.dev/pod-selector: "app.kubernetes.io/name=lidarr"
    gethomepage.dev/group: "Media"
    gethomepage.dev/icon: "lidarr.svg"
    gethomepage.dev/href: "https://lidarr.lab.supermorphic.com"
spec:
  hostnames:
    - lidarr.lab.supermorphic.com
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: internal
      namespace: networking
      sectionName: https
  rules:
    - backendRefs:
        - group: ""
          kind: Service
          name: lidarr
          port: 8686
          weight: 1
      matches:
        - path:
            type: PathPrefix
            value: /
```

Do not add any key beginning `gethomepage.dev/widget.` in PR 1.

- [ ] **Step 7: Wire Lidarr into the media root and validate four apps**

Add `- ./lidarr/ks.yaml` after Radarr in `kubernetes/apps/media/kustomization.yaml`, then run:

```bash
mise exec -- just kube arr-validate
```

Expected: the original three `OK` lines plus `lidarr 3.1.2.4902 OK`; no Gatus or widget assertion is required while Lidarr is suspended.

- [ ] **Step 8: Commit the staged application**

```bash
mise exec -- git add \
  kubernetes/apps/media/lidarr \
  kubernetes/apps/media/kustomization.yaml \
  scripts/validate/arr.sh
mise exec -- git commit -m "feat(media): stage lidarr application"
```

### Task 3: Extend the Guarded `*arr` Tooling and Catalog

**Files:**
- Modify: `scripts/verify/arr.sh:5-16`
- Modify: `.just/bootstrap.just:1287-1350`
- Modify: `.just/repository.just:751-836`
- Modify: `kubernetes/mod.just:550-561`
- Modify: `tests/catalog.yaml:50-70,350-370`

**Interfaces:**
- Consumes: Flux Kustomization/HelmRelease/HTTPRoute name `lidarr`, `/ping`, and port `8686` from Task 2.
- Produces: `mise exec -- just bootstrap arr lidarr`, confirmation `bootstrap:arr:lidarr`, catalog ID `verification.lidarr`, and Secret recipe `homepage-lidarr-secrets`.

- [ ] **Step 1: Add Lidarr to live verification dispatch**

Change both usage strings and the allowlist in `scripts/verify/arr.sh` from `prowlarr|sonarr|radarr` to `prowlarr|sonarr|radarr|lidarr`. The remaining implementation is already app-derived and must stay unchanged.

- [ ] **Step 2: Strengthen and generalize the bootstrap guard**

Make these exact semantic changes in `.just/bootstrap.just`:

```bash
case "$app" in
  prowlarr|sonarr|radarr|lidarr) ;;
  *) echo "Usage: just bootstrap arr <prowlarr|sonarr|radarr|lidarr>" >&2; exit 1 ;;
esac
expected_confirmation="bootstrap:arr:$app"
```

Add these files to the existing `require_deployed_source "$app bootstrap"` call:

```text
scripts/validate/arr.sh
scripts/verify/arr.sh
tests/catalog.yaml
```

Rewrite the recipe comment, failure cleanup, confirmation refusal, recommended order, and success message without `Phase 13`. The recommended order is `prowlarr`, then `sonarr`, `radarr`, and `lidarr` as each becomes ready; the success message sends the operator to `docs/arr-stack-startup.md` rather than embedding an incomplete TV/movie-only setup list.

- [ ] **Step 3: Add the Homepage Lidarr Secret recipe**

Add `homepage-lidarr-secrets` next to the other `*arr` recipes in `.just/repository.just` by using these exact names:

```text
input: LIDARR_API_KEY
confirmation variable: HOMEPAGE_LIDARR_SECRETS_CONFIRM
confirmation value: write:monitoring:homepage-lidarr:sops
target: kubernetes/apps/monitoring/homepage/app/homepage-lidarr.sops.yaml
Secret metadata.name: homepage-lidarr
Secret metadata.namespace: homepage
Secret stringData key: apiKey
temporary directory prefix: /tmp/homelab-talos-homepage-lidarr.
```

The recipe must call `just repo secrets`, use `umask 077`, generate plaintext only inside the trapped temporary directory, encrypt with `sops --filename-override "$target"`, verify encrypted status and the repository age recipient, assert the API key is absent from ciphertext, then `mv` only the encrypted file to the target.

- [ ] **Step 4: Update recipe descriptions and catalog registration**

In `kubernetes/mod.just`, describe `arr-validate` and `arr-verify` as current `*arr` workflows, list all four apps, and remove phase wording.

Add `verification.lidarr` immediately after `verification.radarr` in `tests/catalog.yaml`:

```yaml
  - metadata: {id: verification.lidarr, source: verification, framework: bash, suite: media, tier: verification, target: lidarr, scenario: null, scope: application, intent: acceptance, mutates_cluster: false, execution_owner: human}
    confirmation: {type: none, variable: null, expected: null}
    runner: {command: "mise exec -- just kube arr-verify lidarr", implementation: scripts/verify/arr.sh}
    native_results: {strategy: wrapper-junit}
```

Also add `verification.lidarr` after `verification.radarr` in the top-level `verification.members` list.

- [ ] **Step 5: Validate static tooling without touching the cluster**

Run:

```bash
mise exec -- just test catalog-validate
mise exec -- just repo lint
mise exec -- just kube arr-validate
```

Expected: catalog validation, repository hooks, and all four app validations pass. Do not run `arr-verify lidarr` before the operator bootstrap.

- [ ] **Step 6: Commit the rollout tooling**

```bash
mise exec -- git add \
  scripts/verify/arr.sh \
  .just/bootstrap.just \
  .just/repository.just \
  kubernetes/mod.just \
  tests/catalog.yaml
mise exec -- git commit -m "feat(lidarr): add guarded rollout tooling"
```

### Task 4: Document Greenfield Lidarr Setup and Manual Acceptance

**Files:**
- Modify: `docs/arr-stack-startup.md:1-42,90-125,200-230,555-598,724-778`

**Interfaces:**
- Consumes: URLs, paths, Secret recipe, and guarded commands from Tasks 2-3.
- Produces: An operator runbook whose required states are authoritative even if Lidarr 3.1.2 moves a UI label.

- [ ] **Step 1: Extend the overview, service table, and order of operations**

Add Lidarr to the introductory service list and table:

```markdown
| Lidarr | `https://lidarr.lab.supermorphic.com` | `http://lidarr.media.svc.cluster.local:8686` | `/config` |
```

Update the ordered workflow so Lidarr authentication/media management/download client follows Radarr, Prowlarr connects to all three downstream apps, and the direct Lidarr import gate occurs before any deferred Plex Music library work.

- [ ] **Step 2: Add the qBittorrent music category and path diagram**

Document category `music` with save path `/data/downloads/music`. Update the tree to include both `/data/downloads/music` and `/data/media/music`, while explaining that Lidarr creates the latter when the root folder is saved because the SMB mount and pod both use UID/GID `568`.

- [ ] **Step 3: Add a complete Lidarr first-run section**

The section must contain these exact required states and outputs:

```markdown
## Lidarr

- Authentication: Forms login, authentication enabled, unique password-manager credential.
- Root folder: `/data/media/music`; never `/data/downloads`.
- Download client: `qbittorrent.media.svc.cluster.local`, port `8080`, no SSL,
  no URL base, category `music`, and no remote path mapping.
- Importing: **Use Hardlinks instead of Copy** enabled.
- Metadata: **Write Metadata to Audio Files** disabled while torrents seed.
- Quality profile: prefer FLAC/lossless, retain a lossy fallback below it.
- Rename tracks: enabled.
- Artist folder: `{Artist}`.
- Album folder output: `{Album}` with no release year.
- Track output: `{Disc}{Track:00} - {Title}` in one album folder, producing
  `101 - Track.ext` and `201 - Track.ext` for multi-disc releases.
- Compilation output: `/data/media/music/Various Artists/{Album}/...`, with embedded
  `Album Artist` equal to `Various Artists` and embedded `Artist` equal to the performer.
```

State that the output is authoritative and the operator must use Lidarr 3.1.2's naming preview to select the tokens shown by the deployed UI. Document that `/ping` does not detect outages of `api.lidarr.audio`; a green pod/Gatus endpoint does not guarantee artist or album searches work.

Add Plex's music naming article `https://support.plex.tv/articles/200265296-adding-music-media-from-folders/` to the upstream references and identify it as the authority for the bare album folder, flat disc/track numbering, and `Various Artists` convention.

- [ ] **Step 4: Add Prowlarr and Homepage wiring**

Add a Prowlarr application table for Lidarr with `Full Sync`, Prowlarr URL `http://prowlarr.media.svc.cluster.local:9696`, application URL `http://lidarr.media.svc.cluster.local:8686`, Lidarr's API key, blank tags, and default sync categories.

Add the no-echo Homepage command block:

```bash
printf 'Lidarr API key: '
IFS= read -r -s LIDARR_API_KEY
printf '\n'
export LIDARR_API_KEY
export HOMEPAGE_LIDARR_SECRETS_CONFIRM='write:monitoring:homepage-lidarr:sops'
mise exec -- just repo homepage-lidarr-secrets
unset LIDARR_API_KEY HOMEPAGE_LIDARR_SECRETS_CONFIRM
```

Explain that this recipe is run only after first boot and that only the encrypted `homepage-lidarr.sops.yaml` enters PR 2.

- [ ] **Step 5: Add the real-import acceptance checklist**

Add a direct Lidarr test requiring one authorized release and all of the following evidence:

```text
qBittorrent category: music
download root: /data/downloads/music
library root: /data/media/music
library naming: Artist/Album/DiscTrack - Title.ext
download-side link count: 2
library-side link count: 2
Write Metadata to Audio Files: disabled
qBittorrent force recheck: completes with no hash error
```

Make clear that this is the blocking gate between PRs, not automated E2E coverage, and that creating the Plex Music library remains deferred. If the operator uses a shell to inspect inode/link counts, it must be through an existing guarded recipe or a NAS-side shell, never raw `kubectl exec`.

- [ ] **Step 6: Validate docs and finish PR 1**

Run:

```bash
mise exec -- just repo lint
mise exec -- just ci
mise exec -- git status --short
```

Expected: the full secret-free CI gate passes and only the intended documentation change remains uncommitted.

Commit:

```bash
mise exec -- git add docs/arr-stack-startup.md
mise exec -- git commit -m "docs(lidarr): add greenfield startup runbook"
```

Immediately before pushing PR 1, run `mise exec -- git fetch origin`, safely rebase the clean feature branch onto `origin/main` if needed, rerun `mise exec -- just ci`, and report the breaking confirmation-string change from `bootstrap:phase13:<app>` to `bootstrap:arr:<app>`. Push/open the PR, but do not merge or enable auto-merge without explicit operator authorization for that merge.

## Blocking Operator Gate Between PRs

Do not begin PR 2 until PR 1 is authorized, merged to `main`, and the following gate passes against that exact deployed `origin/main` source:

1. The operator runs:

   ```bash
   export ARR_BOOTSTRAP_CONFIRM='bootstrap:arr:lidarr'
   mise exec -- just bootstrap arr lidarr
   unset ARR_BOOTSTRAP_CONFIRM
   ```

2. The operator configures authentication, Prowlarr, qBittorrent category/client, `/data/media/music`, lossless-preferred quality, the authoritative naming output, hardlinks enabled, and metadata writes disabled.
3. The operator imports one authorized release and records the exact Lidarr 3.1.2 naming tokens/UI labels, both link counts, and the qBittorrent force-recheck result.
4. If the deployed labels or tokens differ from PR 1 wording, PR 2 corrects the runbook using the recorded exact UI strings without changing the authoritative output or safety states.
5. The operator creates the encrypted widget Secret:

   ```bash
   printf 'Lidarr API key: '
   IFS= read -r -s LIDARR_API_KEY
   printf '\n'
   export LIDARR_API_KEY
   export HOMEPAGE_LIDARR_SECRETS_CONFIRM='write:monitoring:homepage-lidarr:sops'
   mise exec -- just repo homepage-lidarr-secrets
   unset LIDARR_API_KEY HOMEPAGE_LIDARR_SECRETS_CONFIRM
   ```

6. Confirm the new file is SOPS-encrypted and contains no plaintext key. Preserve it unmodified for PR 2.

---

## PR 2 — Activation, Monitoring, Homepage, and Music Policy

Start PR 2 from a clean branch based on the post-PR-1 `origin/main`, carrying only the operator-generated `homepage-lidarr.sops.yaml` as the expected initial change.

### Task 5: Consolidate qbit_manage Share-Limit Validation Without Music

**Files:**
- Modify: `scripts/validate/qbit-manage.sh:102-114`
- Modify: `scripts/validate/qbit-manage-policy.sh:75-147`
- Modify: `scripts/test/qbit-manage-policy-validator-test.sh:66-136`

**Interfaces:**
- Consumes: Existing `public` and `czteam` groups from `config.yml`.
- Produces: `assert_share_limit_group NAME RATIO MIN MAX ACTION CLEANUP` plus three set-wide invariants that accept future group names without code changes.

- [ ] **Step 1: Capture the pre-refactor qbit_manage baseline**

Run:

```bash
qbm_baseline_dir="$(mktemp -d /tmp/lidarr-qbm-baseline.XXXXXX)"
mise exec -- just kube qbit-manage-validate >"$qbm_baseline_dir/before.txt"
mise exec -- just test validate >"$qbm_baseline_dir/tests-before.txt"
```

Expected: both commands exit `0`. Keep `qbm_baseline_dir` through Step 5.

- [ ] **Step 2: Write failing tests for the generalized invariants**

In `scripts/test/qbit-manage-policy-validator-test.sh`, replace the pairwise CZTeam/public priority expectation and add cases that mutate a copied production config as follows:

```bash
# A future finite-stop group above CZTeam must fail even when cleanup is false.
yq -i '.share_limits.future = {
  "priority": 5, "max_ratio": 1.0, "min_seeding_time": "1d",
  "max_seeding_time": "7d", "share_limit_action": "Stop", "cleanup": false
}' "$test_config"

# Every cleanup group must carry both private exclusions.
yq -i '.share_limits.future = {
  "priority": 50, "exclude_any_tags": ["tracker-private"],
  "max_ratio": 1.0, "min_seeding_time": "1d", "max_seeding_time": "7d",
  "share_limit_action": "Stop", "cleanup": true
}' "$test_config"

# Resolution priorities must be unique.
yq -i '.share_limits.future = {
  "priority": 100, "max_ratio": 1.0, "min_seeding_time": "1d",
  "max_seeding_time": "7d", "share_limit_action": "Stop", "cleanup": false
}' "$test_config"
```

Expect messages containing, respectively:

```text
share_limits.czteam.priority must be the strict minimum across all groups
Every cleanup-enabled share_limits group must exclude tracker-private and tracker-czteam
share_limits priorities must be unique
```

Run `mise exec -- just test validate`. Expected: FAIL because the old pairwise validator does not enforce these cases.

- [ ] **Step 3: Move exact policy values into one helper**

Delete the `share_limits.public` number block from `scripts/validate/qbit-manage.sh`. In `scripts/validate/qbit-manage-policy.sh`, define a helper with this signature and behavior:

```bash
assert_share_limit_group() {
  local name="$1" expected_ratio="$2" expected_min="$3"
  local expected_max="$4" expected_action="$5" expected_cleanup="$6"
  local group=".share_limits.$name" actual_ratio

  [[ "$(yq -r "$group // \"none\"" "$config")" != 'none' ]] || {
    echo "config.yml must define share_limits.$name." >&2
    exit 1
  }
  actual_ratio="$(yq -r "$group.max_ratio" "$config")"
  [[ "$actual_ratio" == "$expected_ratio" || \
    ( "$expected_ratio" == *.0 && "$actual_ratio" == "${expected_ratio%.0}" ) ]] || {
    echo "share_limits.$name.max_ratio must be $expected_ratio." >&2
    exit 1
  }
  [[ "$(yq -r "$group.min_seeding_time" "$config")" == "$expected_min" ]] || {
    echo "share_limits.$name.min_seeding_time must be $expected_min." >&2
    exit 1
  }
  [[ "$(yq -r "$group.max_seeding_time" "$config")" == "$expected_max" ]] || {
    echo "share_limits.$name.max_seeding_time must be $expected_max." >&2
    exit 1
  }
  [[ "$(yq -r "$group.share_limit_action" "$config")" == "$expected_action" ]] || {
    echo "share_limits.$name.share_limit_action must be $expected_action." >&2
    exit 1
  }
  [[ "$(yq -r "$group.cleanup" "$config")" == "$expected_cleanup" ]] || {
    echo "share_limits.$name.cleanup must be $expected_cleanup." >&2
    exit 1
  }
}

assert_share_limit_group public 1.5 1d 7d Stop true
assert_share_limit_group czteam 2.0 7d -1 Stop false
```

Keep selector checks separate: public categories exactly `movies,tv`; public excludes both private tags; CZTeam includes `tracker-czteam`. The dual scalar form for `2.0` is intentional.

- [ ] **Step 4: Implement the three set-wide invariants**

Use `yq` over `.share_limits | to_entries[]` so no future group name is embedded in these checks:

```bash
invalid_priorities=''
while IFS='|' read -r group priority; do
  if [[ ! "$priority" =~ ^[0-9]+$ ]]; then
    invalid_priorities+="${invalid_priorities:+,}$group"
  fi
done < <(yq -r '.share_limits | to_entries[] | [.key, .value.priority] | join("|")' "$config")
[[ -z "$invalid_priorities" ]] || {
  echo 'Every share_limits priority must be a non-negative integer.' >&2
  exit 1
}

unsafe_precedence="$(yq -r '
  .share_limits.czteam.priority as $cz
  | .share_limits
  | to_entries[]
  | select(.key != "czteam")
  | select(.value.priority <= $cz)
  | .key
' "$config")"
[[ -z "$unsafe_precedence" ]] || {
  echo 'share_limits.czteam.priority must be the strict minimum across all groups.' >&2
  exit 1
}

unsafe_cleanup="$(yq -r '
  .share_limits
  | to_entries[]
  | select(.value.cleanup == true)
  | select(
      ((.value.exclude_any_tags // []) | contains(["tracker-private"])) == false
      or ((.value.exclude_any_tags // []) | contains(["tracker-czteam"])) == false
    )
  | .key
' "$config")"
[[ -z "$unsafe_cleanup" ]] || {
  echo 'Every cleanup-enabled share_limits group must exclude tracker-private and tracker-czteam.' >&2
  exit 1
}

priority_count="$(yq -r '.share_limits | length' "$config")"
unique_priority_count="$(yq -r '[.share_limits[].priority] | unique | length' "$config")"
[[ "$priority_count" == "$unique_priority_count" ]] || {
  echo 'share_limits priorities must be unique.' >&2
  exit 1
}
```

Keep the strict-minimum check before uniqueness so the existing `czteam.priority = 100` mutation fails for unsafe precedence, and use the extra `future` group to isolate uniqueness coverage.

- [ ] **Step 5: Prove the refactor is inert before adding music**

Run:

```bash
mise exec -- just test validate
mise exec -- just kube qbit-manage-validate >"$qbm_baseline_dir/after-refactor.txt"
mise exec -- git diff --no-index --exit-code \
  "$qbm_baseline_dir/before.txt" "$qbm_baseline_dir/after-refactor.txt"
```

Expected: all focused shell/Python tests pass and validation output is byte-for-byte unchanged. This differential check is the safety proof for moving public policy ownership.

- [ ] **Step 6: Commit the validator restructure**

```bash
mise exec -- git add \
  scripts/validate/qbit-manage.sh \
  scripts/validate/qbit-manage-policy.sh \
  scripts/test/qbit-manage-policy-validator-test.sh
mise exec -- git commit -m "refactor(qbit-manage): generalize share-limit validation"
```

### Task 6: Add the qbit_manage Music Policy and Documentation

**Files:**
- Modify: `scripts/validate/qbit-manage-policy.sh`
- Modify: `scripts/test/qbit-manage-policy-validator-test.sh`
- Modify: `kubernetes/apps/media/qbit-manage/app/config.yml:94-139`
- Modify: `kubernetes/apps/media/qbit-manage/app/values.yaml:21-28`
- Modify: `docs/qbit-manage.md:1-47,228-288`

**Interfaces:**
- Consumes: `assert_share_limit_group` and set-wide invariants from Task 5; qBittorrent category `music` from the operator gate.
- Produces: qbit_manage group `music`, exact music selector checks, and a config hash that forces Deployment rollout.

- [ ] **Step 1: Add failing exact-value tests for music**

Add tests that initially expect production policy validation to fail because `.share_limits.music` is missing. After the group exists, mutate each of these fields one at a time and expect a field-specific failure: `max_ratio`, `min_seeding_time`, `max_seeding_time`, `share_limit_action`, `cleanup`, `categories`, and each required exclusion tag.

Also retain a passing case where music `max_ratio` is serialized as either `2` or `2.0`.

Run `mise exec -- just test validate`. Expected: FAIL with `config.yml must define share_limits.music.` after the validator call is added.

- [ ] **Step 2: Add music selector and exact-value validation**

Add:

```bash
music='.share_limits.music'
music_categories="$(yq -o=json -I=0 "$music.categories | sort" "$config")"
[[ "$music_categories" == '["music"]' ]] || {
  echo 'share_limits.music.categories must contain exactly music.' >&2
  exit 1
}
for private_tag in tracker-private tracker-czteam; do
  [[ "$(yq -r "($music.exclude_any_tags // []) | contains([\"$private_tag\"])" "$config")" == 'true' ]] || {
    echo "share_limits.music.exclude_any_tags must include $private_tag." >&2
    exit 1
  }
done
assert_share_limit_group music 2.0 7d 30d Stop true
```

Place the call between public and CZTeam so the three expected policies read in priority-domain order without changing the set-wide logic.

- [ ] **Step 3: Add the production music group**

Add this exact group between `czteam` and `public` in `config.yml`:

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

Update the surrounding comment to explain: one group match per torrent; CZTeam priority `10` wins first; music excludes both private tags as independent fall-through protection; ratio `2.0` cannot stop before `7d`; `30d` is unconditional; cleanup moves only the download-side name into the seven-day recycle bin while the library hardlink remains.

- [ ] **Step 4: Stamp and validate the config hash**

Run:

```bash
mise exec -- git hash-object kubernetes/apps/media/qbit-manage/app/config.yml
```

Copy the exact output into `controllers.qbit-manage.pod.annotations.config-hash` in `values.yaml`, then run:

```bash
mise exec -- just test validate
mise exec -- just kube qbit-manage-validate
```

Expected: PASS with production now containing three groups. The new music group is the only semantic difference from Task 5's baseline.

- [ ] **Step 5: Rewrite qbit_manage's model and safety documentation**

Update the overview from movie/TV-only to movie/TV/music. Replace the flow with:

```text
CZTeam tag + any category ─────────────► czteam (10): 7d minimum, ratio 2.0,
                                         unlimited maximum, Stop, no cleanup
music without private tags ───────────► music (50): 7d minimum, ratio 2.0,
                                         30d maximum, Stop, recycle cleanup
tv/movies without private tags ───────► public (100): 1d minimum, ratio 1.5,
                                         7d maximum, Stop, recycle cleanup
```

Document the two independent generalized invariants exactly:

1. `czteam.priority` is strictly lower than every other group and every priority is unique.
2. Every `cleanup: true` group excludes both `tracker-private` and `tracker-czteam`.

Explain the distinct failure each catches, the hardlink reason longer music seeding has near-zero marginal storage cost, and that the remaining operational cost is qBittorrent tracking more active torrents. Update quick-disable/recovery examples to name both cleanup groups where relevant.

- [ ] **Step 6: Commit the music policy**

```bash
mise exec -- git add \
  scripts/validate/qbit-manage-policy.sh \
  scripts/test/qbit-manage-policy-validator-test.sh \
  kubernetes/apps/media/qbit-manage/app/config.yml \
  kubernetes/apps/media/qbit-manage/app/values.yaml \
  docs/qbit-manage.md
mise exec -- git commit -m "feat(qbit-manage): add music seeding policy"
```

### Task 7: Activate Lidarr with Gatus and Homepage

**Files:**
- Modify: `kubernetes/apps/media/lidarr/ks.yaml:20`
- Modify: `kubernetes/apps/media/lidarr/app/httproute.yaml:8-18`
- Modify: `kubernetes/apps/monitoring/gatus/app/values.yaml:110-132`
- Create: `kubernetes/apps/monitoring/homepage/app/homepage-lidarr.sops.yaml` (already operator-generated; preserve ciphertext)
- Modify: `kubernetes/apps/monitoring/homepage/app/kustomization.yaml:4-16`
- Modify: `kubernetes/apps/monitoring/homepage/app/deployment.yaml:90-115`
- Modify: `scripts/validate/homepage.sh:100-175`
- Modify: `docs/arr-stack-startup.md` only if the operator gate recorded different Lidarr 3.1.2 UI labels/tokens.

**Interfaces:**
- Consumes: Operator-accepted Lidarr instance and encrypted Secret `homepage-lidarr` with key `apiKey`.
- Produces: Active Flux source, Gatus endpoint `lidarr`, and Homepage variable `HOMEPAGE_VAR_LIDARR_API_KEY` used by the route annotation.

- [ ] **Step 1: Demonstrate the activation-aware guard before completing activation**

Change Lidarr to `suspend: false` without adding Gatus/widget metadata, then run:

```bash
mise exec -- just kube arr-validate
```

Expected: FAIL with `Active lidarr has no Gatus endpoint.` This proves the staged-to-active safety transition is enforced. Do not commit this intermediate state.

- [ ] **Step 2: Add the Gatus endpoint**

Add after Radarr:

```yaml
    - name: lidarr
      group: Media
      url: "https://lidarr.lab.supermorphic.com/ping"
      interval: 1m
      conditions:
        - "[STATUS] == 200"
```

- [ ] **Step 3: Publish the complete Homepage widget contract**

Add all three widget annotations together to Lidarr's HTTPRoute:

```yaml
    gethomepage.dev/widget.type: "lidarr"
    gethomepage.dev/widget.url: "http://lidarr.media.svc.cluster.local:8686"
    gethomepage.dev/widget.key: "{{HOMEPAGE_VAR_LIDARR_API_KEY}}"
```

The existing icon, group, and description remain `lidarr.svg`, `Media`, and `Music`.

- [ ] **Step 4: Reconcile and expose the encrypted Secret**

Add `./homepage-lidarr.sops.yaml` to Homepage's kustomization next to the other `*arr` Secrets. Add this optional env entry to the Deployment:

```yaml
            # Lidarr widget API key (optional: widget blank until
            # `just repo homepage-lidarr-secrets` creates the encrypted Secret).
            - name: HOMEPAGE_VAR_LIDARR_API_KEY
              valueFrom:
                secretKeyRef:
                  name: homepage-lidarr
                  key: apiKey
                  optional: true
```

Do not change `spec.template.metadata.annotations.sops-hash`; it remains the hash of `homepage-ntfy.sops.yaml`. The env-list change itself rolls Homepage.

- [ ] **Step 5: Extend Homepage validation**

Add `lidarr_secret="$base/app/homepage-lidarr.sops.yaml"`; require the file, `sops filestatus` encrypted `true`, metadata name `homepage-lidarr`, and namespace `homepage`. Add env assertions for name `HOMEPAGE_VAR_LIDARR_API_KEY`, Secret `homepage-lidarr`, key `apiKey`, and `optional: true`.

If Step 1's validation now reaches widget checks but exits without a useful diagnostic, improve the Task 1 widget assertions to print the expected derived type, URL, or key before exit; keep behavior identical for the other three apps.

- [ ] **Step 6: Validate the complete activation source**

Run:

```bash
mise exec -- just kube arr-validate
mise exec -- just kube gatus-validate
mise exec -- just kube homepage-validate
mise exec -- just kube qbit-manage-validate
mise exec -- just test validate
mise exec -- just ci
```

Expected: all commands pass; Lidarr is active only now that Gatus and all widget dependencies coexist; no plaintext API key appears in tracked or untracked files.

- [ ] **Step 7: Commit activation**

```bash
mise exec -- git add \
  kubernetes/apps/media/lidarr/ks.yaml \
  kubernetes/apps/media/lidarr/app/httproute.yaml \
  kubernetes/apps/monitoring/gatus/app/values.yaml \
  kubernetes/apps/monitoring/homepage/app/homepage-lidarr.sops.yaml \
  kubernetes/apps/monitoring/homepage/app/kustomization.yaml \
  kubernetes/apps/monitoring/homepage/app/deployment.yaml \
  scripts/validate/homepage.sh \
  scripts/validate/arr.sh \
  docs/arr-stack-startup.md
mise exec -- git commit -m "feat(lidarr): activate monitoring and homepage"
```

Only stage `scripts/validate/arr.sh` or the startup guide if Step 5 or the operator-recorded UI facts required a real correction.

### Task 8: Final PR 2 Validation and Authorized Rollout Handoff

**Files:**
- Verify all PR 2 files; no new implementation file is introduced by this task.

**Interfaces:**
- Consumes: All PR 2 commits and current `origin/main`.
- Produces: Reviewable PR evidence and, after an explicitly authorized merge, the definition-of-done live checks.

- [ ] **Step 1: Review the two-layer qbit_manage diff**

Run:

```bash
mise exec -- git diff origin/main...HEAD -- \
  scripts/validate/qbit-manage.sh \
  scripts/validate/qbit-manage-policy.sh \
  scripts/test/qbit-manage-policy-validator-test.sh \
  kubernetes/apps/media/qbit-manage/app/config.yml
```

Confirm from the diff that public numeric checks exist only in the policy validator, all three exact helper calls are present, no set-wide check names `public` or `music`, and both safety invariants plus priority uniqueness have negative tests.

- [ ] **Step 2: Run the canonical final gate from a clean tree**

Run:

```bash
mise exec -- git status --short
mise exec -- just ci
mise exec -- git status --short
```

Expected: CI exits `0` and does not create tracked changes. Report every validation actually run and the intentional omissions: no Lidarr Chainsaw test, no automated real music download, no Plex Music library.

- [ ] **Step 3: Synchronize immediately before push**

Run:

```bash
mise exec -- git fetch origin
mise exec -- git rebase origin/main
mise exec -- just ci
```

Push/open PR 2 only after the clean rebase and passing rerun. Do not merge or enable auto-merge without explicit authorization for this specific merge.

- [ ] **Step 4: After authorized merge, run read-only live acceptance**

After Flux has reconciled the exact merged `origin/main`, the operator runs guarded checks:

```bash
mise exec -- just kube arr-verify lidarr
mise exec -- just kube gatus-verify
mise exec -- just kube homepage-verify
mise exec -- just kube qbit-manage-verify
```

Then confirm in the application UIs that Gatus shows Lidarr green, the Homepage widget renders, qBittorrent has category `music` at `/data/downloads/music`, qbit_manage reports music torrents selecting `music` while CZTeam music selects `czteam`, and the accepted library file still has link count `2` with a clean qBittorrent force recheck.

- [ ] **Step 5: Report completion and remaining operational risks**

Report the complete changed-file list, commit/PR split, exact validation commands and outcomes, operator-gate evidence, and these remaining risks: `api.lidarr.audio` can fail while `/ping` remains green; `1Gi` may need later adjustment during a large metadata refresh; hardlink and metadata-write safety remain first-run application settings; and no synthetic external-metadata monitor or automated functional download test exists.
