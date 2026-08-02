# FileFlows Movie Encoding Benchmark Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and operate a reversible, GitOps-managed benchmark harness that decides whether Intel Quick Sync HEVC encoding is worth pursuing for each movie cohort before FileFlows is deployed.

**Architecture:** Flux reconciles only inert benchmark inputs: hashed shell scripts, a pinned sample ConfigMap, a negative PriorityClass, and Prometheus alert rules. Guarded recipes render short-lived Jobs from a non-reconciled template; those Jobs mount movies read-only, write only under `benchmark/`, use node-local scratch, and record immutable run identities before encoding. Delivery uses four review boundaries so the runtime image is proven on real i915 hardware before the census, census-derived samples are committed before quality work, visually approved cohort settings reach `origin/main` before full-title savings runs, and the final decision is reviewed separately from the harness.

**Tech Stack:** Talos Linux, Kubernetes 1.35, Flux, Kustomize, Kubernetes Jobs and PriorityClass, Intel i915/QSV via oneVPL, FFmpeg/ffprobe, libvmaf, libx265, Bash 5, Bats, `shfmt`, `shellcheck`, `jq`, `awk`, Python 3 from the existing qbit_manage image, Prometheus/Alertmanager/ntfy, `just`, and the repository's pinned `mise` toolchain.

## Global Constraints

- Work only on branch `fileflows-movie-encoding-strategy`; never commit, push, merge, or enable auto-merge on `main`.
- Immediately before each push, run `mise exec -- git fetch origin`; rebase a clean branch onto `origin/main` only when it is behind.
- Never merge without explicit operator authorization for that specific merge.
- Run repository workflows with `mise exec -- just <recipe>`; run pinned ad hoc tools with `mise exec -- <tool> <arguments>`.
- Use only guarded `just` recipes for cluster checks and mutations. The operator runs bootstrap, census, benchmark, and cleanup recipes.
- Do not edit `docs/decisions/2026-08-01-fileflows-movie-encoding.md`; it is accepted and may only be superseded by a new dated record.
- Do not deploy FileFlows, touch `intel-gpu-plugin`, change the Plex Deployment/HelmRelease, add `priorityClassName` to Plex, evaluate TV, encode Dolby Vision, prune audio, or create ntfy credentials.
- `media/tv` and `downloads/` are never mounted into a benchmark Job. `/media` is `media-data` with `subPath: media/movies`, read-only; `/out` is `media-data` with `subPath: benchmark`, read-write.
- The census Job mounts `/media` and `/out`, requests no GPU, and mounts no scratch volume.
- An encode Job requests and limits `gpu.intel.com/i915: 1`, uses required pod anti-affinity against `app.kubernetes.io/name=plex`, runs as UID/GID `568`, drops `ALL` capabilities, never retries, and has an active deadline.
- Use PriorityClass `encode-benchmark-background` with value `-10`, `globalDefault: false`, and `preemptionPolicy: Never`.
- Use a `150Gi` scratch request and `emptyDir.sizeLimit`, a `160Gi` ephemeral-storage limit, and require at least `200Gi` free in read-only preflight. This deliberately leaves a `50Gi` free-space margin while preserving the accepted placement gap.
- The initial runtime candidate is the immutable amd64 image `docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb` (`8.1.2-cli-ls73`). It is not promoted to `verified` until the guarded capability Job proves every §7.1 requirement on an i915 node.
- A capability failure blocks census and encoding. Do not weaken a requirement; record the failed capability and select another immutable digest or the authorized encode/analysis two-image split in a new reviewable commit.
- QSV quality settings are `global_quality` `20`, `22`, `24`, `26`, and `28`, with lookahead and extbrc; x265 starts at CRF `18`, `20`, `22`, and `24` and extends only until the QSV VMAF point is bracketed.
- Quality eligibility is per clip: VMAF harmonic mean `>=95`, VMAF 1% low `>=90`, zero output-validation failures, selected rate control exactly `LA-ICQ`, non-suspect GPU telemetry, and operator visual `PASS`.
- Savings verdicts use median reduction by cohort: `>=25%` GO, `15%` through `<25%` MARGINAL, and `<15%` NO-GO. Report median and IQR.
- x265 comparison uses interpolation only: QSV premium `<=15%` is preferred, `>15%` through `30%` is acceptable with cost noted, `>30%` escalates, and an unbracketed point has no verdict.
- Every run writes `/out/runs/<run-id>/manifest.json` first and never modifies it. A supplied run ID resumes only when the recomputed identity is byte-equivalent; divergence aborts with a field diff.
- Clip and savings outputs stay in `/scratch` and are deleted after measurement. Only operator-selected finalist full-title outputs are copied to `encodes/`.
- Run `mise exec -- just ci` before every implementation PR. Keep `*-verify`, `*-preflight`, live capability checks, census, benchmark execution, and cleanup out of `just ci`.
- Never decrypt, rewrite, or expose `qbit-manage-secret.sops.yaml`. Lifecycle inventory executes read-only inside the existing qbit_manage pod, consumes its already-injected `QBT_USER`/`QBT_PASS`, and emits only inode, torrent hash, tags, category, and lifecycle state.

## Delivery Boundaries and File Map

### PR 1 — Suspended harness and capability gate

- Modify `.mise.toml` and `mise.lock` — pin Bats `1.13.0`, `shfmt` `3.13.1`, and FFmpeg/ffprobe `8.1.2`.
- Modify `.just/repository.just` — print the pinned harness-tool versions and update the guarded-rollout source-count assertion.
- Create `kubernetes/apps/media/encode-benchmark/ks.yaml` — suspended Flux child.
- Create `kubernetes/apps/media/encode-benchmark/app/kustomization.yaml` — scripts ConfigMap plus inert resources.
- Create `kubernetes/apps/media/encode-benchmark/app/priorityclass.yaml` — negative background priority.
- Create `kubernetes/apps/media/encode-benchmark/app/samples.yaml` — candidate image, schema, seed, empty pre-census panels, and capability state.
- Create `kubernetes/apps/media/encode-benchmark/app/alerts.yaml` — completion/failure alerts through the existing Alertmanager route.
- Create `kubernetes/apps/media/encode-benchmark/app/scripts/{probe,census,runmeta,benchmark,stills}.sh` — runtime harness.
- Create `kubernetes/apps/media/encode-benchmark/templates/job.yaml` — valid but never reconciled Job template.
- Create `kubernetes/apps/media/encode-benchmark/tests/{fixtures,golden}/*` and `*.bats` — offline contract tests.
- Create `scripts/validate/encode-benchmark.sh` — cluster-independent source and render validation.
- Create `scripts/verify/encode-benchmark.sh` — read-only live acceptance.
- Create `scripts/encode-benchmark/{dispatch,preflight,results,select-samples}.sh` — guarded orchestration helpers.
- Create `scripts/encode-benchmark/torrent-inventory.py` — credential-redacted inode/lifecycle bridge executed inside qbit_manage.
- Modify `kubernetes/apps/media/kustomization.yaml` — register the suspended Flux child.
- Modify `kubernetes/mod.just` — validate, preflight, capability, census, run, verify, results, and clean recipes.
- Modify `.just/bootstrap.just` — guarded suspended rollout.
- Modify `tests/catalog.yaml` — CI validation and operator verification entries.

### PR 2 — Verified image, pinned panels, inert activation

- Modify `kubernetes/apps/media/encode-benchmark/app/samples.yaml` — record capability evidence, seven quality titles and clip timestamps, about 24 seeded savings titles, source sizes, and SHA-256 hashes.
- Modify `kubernetes/apps/media/encode-benchmark/ks.yaml` — persist `spec.suspend: false` after bootstrap succeeds.

### PR 3 — Approved settings

- Modify `kubernetes/apps/media/encode-benchmark/app/samples.yaml` — record per-cohort winning QSV settings after quality and visual review.

### PR 4 — Final decision

- Create `docs/decisions/YYYY-MM-DD-fileflows-movie-encoding-findings.md` — sanitized benchmark decision derived from one exact run ID; use the actual completion date in the filename.

The run directory also contains `findings.md`; the committed dated decision is the durable, Git-reviewed copy. Raw movie paths, source hashes, stills, encodes, Plex session data, and NAS telemetry stay on the benchmark share and are not committed.

---

### Task 1: Pin the Harness Test Toolchain

**Files:**
- Modify: `.mise.toml:6-33`
- Modify: `mise.lock`
- Modify: `.just/repository.just:16-34`

**Interfaces:**
- Consumes: The repository's `mise` lock workflow and `repo versions` recipe.
- Produces: Pinned commands `bats` `1.13.0`, `shfmt` `3.13.1`, and `ffmpeg`/`ffprobe` `8.1.2` available to fixture generation, `encode-benchmark-validate`, and CI.

- [ ] **Step 1: Add exact tool pins**

Add these entries under `[tools]` in `.mise.toml`:

```toml
"aqua:bats-core/bats-core" = "1.13.0"
"aqua:mvdan/sh" = "3.13.1"
"conda:ffmpeg" = "8.1.2"
```

Add these lines to the `versions` recipe in `.just/repository.just`:

```just
    @bats --version
    @shfmt --version
    @ffmpeg -version | head -n 1
    @ffprobe -version | head -n 1
```

- [ ] **Step 2: Regenerate the lock and prove both binaries**

Run:

```bash
mise exec -- mise lock
mise exec -- mise install --locked
mise exec -- bats --version
mise exec -- shfmt --version
mise exec -- ffmpeg -version
mise exec -- ffprobe -version
```

Expected: Bats prints `Bats 1.13.0`, `shfmt` prints `v3.13.1`, both FFmpeg commands print version `8.1.2`, and `mise.lock` contains locked platform artifacts for all three tool packages.

- [ ] **Step 3: Commit the independently useful toolchain change**

```bash
mise exec -- git add .mise.toml mise.lock .just/repository.just
mise exec -- git commit -m "build: pin benchmark shell test tools"
```

### Task 2: Add the Suspended Inert Flux Sources and Job Safety Contract

**Files:**
- Create: `kubernetes/apps/media/encode-benchmark/ks.yaml`
- Create: `kubernetes/apps/media/encode-benchmark/app/kustomization.yaml`
- Create: `kubernetes/apps/media/encode-benchmark/app/priorityclass.yaml`
- Create: `kubernetes/apps/media/encode-benchmark/app/samples.yaml`
- Create: `kubernetes/apps/media/encode-benchmark/app/alerts.yaml`
- Create: `kubernetes/apps/media/encode-benchmark/app/scripts/not-ready.sh`
- Create: `kubernetes/apps/media/encode-benchmark/templates/job.yaml`
- Create: `kubernetes/apps/media/encode-benchmark/tests/source-contract.bats`
- Create: `scripts/validate/encode-benchmark.sh`
- Modify: `kubernetes/apps/media/kustomization.yaml:4-15`

**Interfaces:**
- Consumes: Flux child pattern, `media-data` PVC, Plex label `app.kubernetes.io/name=plex`, kube-state-metrics, and the candidate image digest.
- Produces: Flux Kustomization `encode-benchmark`; ConfigMaps `encode-benchmark-scripts-*` and `encode-benchmark-samples`; PriorityClass `encode-benchmark-background`; PrometheusRule `encode-benchmark`; render-only Job template `encode-benchmark-template`.

- [ ] **Step 1: Write failing source-contract tests**

Create `source-contract.bats` with tests that run `kustomize build` and `yq` and assert:

```bash
@test "Flux renders inert resources but no Job" {
  run kustomize build kubernetes/apps/media/encode-benchmark/app
  [ "$status" -eq 0 ]
  [ "$(yq -r 'select(.kind == "Job") | .metadata.name' <<<"$output")" = "" ]
  [ "$(yq -r 'select(.kind == "PriorityClass") | .value' <<<"$output")" = "-10" ]
}

@test "template cannot see TV or downloads and movies are read-only" {
  template=kubernetes/apps/media/encode-benchmark/templates/job.yaml
  [ "$(yq -r '.spec.template.spec.volumes[] | select(.name == "media") | .persistentVolumeClaim.claimName' "$template")" = media-data ]
  [ "$(yq -r '.spec.template.spec.containers[0].volumeMounts[] | select(.name == "media") | .readOnly' "$template")" = true ]
  [ "$(yq -r '.spec.template.spec.containers[0].volumeMounts[] | select(.name == "media") | .mountPath' "$template")" = /media ]
  [ "$(yq -r '.spec.template.spec.containers[0].volumeMounts[] | select(.name == "media") | .subPath' "$template")" = media/movies ]
  ! rg -n '/data|media/tv|downloads' "$template"
}
```

Run:

```bash
mise exec -- bats kubernetes/apps/media/encode-benchmark/tests/source-contract.bats
```

Expected: FAIL because the sources do not exist.

- [ ] **Step 2: Create the suspended Flux child**

Use the established Flux schema and set:

```yaml
spec:
  dependsOn:
    - name: media-storage
    - name: intel-gpu-plugin
    - name: qbit-manage
    - name: kube-prometheus-stack
  interval: 1h
  path: ./kubernetes/apps/media/encode-benchmark/app
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

Register `./encode-benchmark/ks.yaml` immediately after `./storage/ks.yaml` in `kubernetes/apps/media/kustomization.yaml`.

- [ ] **Step 3: Create the inert resources**

`app/kustomization.yaml` must contain only:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: media
resources:
  - ./priorityclass.yaml
  - ./samples.yaml
  - ./alerts.yaml
configMapGenerator:
  - name: encode-benchmark-scripts
    files:
      - probe.sh=scripts/not-ready.sh
      - census.sh=scripts/not-ready.sh
      - runmeta.sh=scripts/not-ready.sh
      - benchmark.sh=scripts/not-ready.sh
      - stills.sh=scripts/not-ready.sh
generatorOptions:
  labels:
    app.kubernetes.io/name: encode-benchmark
```

Create the PriorityClass with value `-10`, `globalDefault: false`, and `preemptionPolicy: Never`.

Create `samples.yaml` as ConfigMap `encode-benchmark-samples` with a single `samples.yaml` data key. Its initial document is:

```yaml
schemaVersion: 1
runtime:
  image: docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb
  capabilityStatus: candidate
  capabilityEvidence: {}
savingsSeed: 20260802
qualityPanel: []
savingsPanel: []
chosenSettings: {}
```

Create two `warning` alerts selected by `namespace="media",job_name=~"encode-benchmark-.*"`: `EncodeBenchmarkJobFailed` on `kube_job_status_failed > 0` and `EncodeBenchmarkJobCompleted` on `kube_job_status_succeeded > 0`, each `for: 1m`. Annotations must name the Job and direct the operator to `mise exec -- just kube encode-benchmark-results <run-id>`; the existing severity route sends both through Alertmanager → alertmanager-ntfy.

Create one shared `scripts/not-ready.sh` fail-closed scaffold so this structural commit renders and validates before the focused implementations land:

```bash
#!/usr/bin/env bash
set -euo pipefail

echo 'This benchmark command is unavailable in the structural source revision.' >&2
exit 64
```

Run `chmod +x` on the scaffold. The five ConfigMap keys intentionally map to this one source file; later tasks replace each mapping with its tested implementation, and Task 5 deletes the scaffold before PR 1 is opened.

- [ ] **Step 4: Create the valid, non-reconciled Job template**

The template is a valid `batch/v1` Job named `encode-benchmark-template` with labels `app.kubernetes.io/name: encode-benchmark`, `homelab-talos/benchmark-run: template`, and `homelab-talos/benchmark-mode: template`. Use:

```yaml
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 86400
  activeDeadlineSeconds: 129600
  template:
    spec:
      priorityClassName: encode-benchmark-background
      restartPolicy: Never
      securityContext:
        runAsNonRoot: true
        runAsUser: 568
        runAsGroup: 568
        fsGroup: 568
        fsGroupChangePolicy: OnRootMismatch
        seccompProfile: {type: RuntimeDefault}
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - topologyKey: kubernetes.io/hostname
              labelSelector:
                matchExpressions:
                  - key: app.kubernetes.io/name
                    operator: In
                    values: [plex]
```

The sole container is `benchmark`, uses the candidate digest, runs `/scripts/benchmark.sh template`, sets `NODE_NAME` from `spec.nodeName`, drops `ALL`, disallows privilege escalation, and has requests `cpu: 2`, `memory: 2Gi`, `ephemeral-storage: 150Gi`, `gpu.intel.com/i915: 1`; limits `cpu: 8`, `memory: 8Gi`, `ephemeral-storage: 160Gi`, `gpu.intel.com/i915: 1`.

Mount:

- `media-data` at `/media`, `subPath: media/movies`, read-only.
- `media-data` at `/out`, `subPath: benchmark`, read-write.
- `emptyDir.sizeLimit: 150Gi` at `/scratch`.
- hashed scripts ConfigMap at `/scripts`, read-only, default mode `0555`.
- samples ConfigMap key at `/config/samples.yaml`, read-only.

Do not list `templates/job.yaml` in any Kustomization.

- [ ] **Step 5: Add cluster-independent validation**

`scripts/validate/encode-benchmark.sh` must:

1. Require every source, template, script, and Bats file present in the current structural revision, and assert the rendered scripts ConfigMap has all five command keys.
2. Assert the Flux child is registered and `suspend` is `true` or `false`.
3. Run `kustomize build`, `kubeconform -strict -summary`, and prove no rendered Job exists.
4. Validate PriorityClass, alerts, candidate/verified digest syntax, script ConfigMap hashing, Job resources, anti-affinity, security, retry/deadline/TTL, and all mount contracts.
5. Reject `/data`, `media/tv`, and `downloads` in app scripts and the Job template.
6. Run `shfmt -d`, `shellcheck --external-sources`, and every Bats file.
7. Refuse `capabilityStatus: verified` unless all eight capability evidence booleans are true and `verifiedAt`, `nodeName`, and `imageId` are non-empty.
8. Refuse non-empty panels until capability status is `verified`; validate sample IDs, cohorts, descendants of absolute path `/media/`, sizes, 64-hex hashes, three distinct quality clip timestamps, exactly one detection-only DV sample, and about eight savings samples per major cohort.

Run:

```bash
mise exec -- just kube encode-benchmark-validate
```

Expected at this stage: PASS with candidate state and empty panels.

- [ ] **Step 6: Commit the inert safety boundary**

```bash
mise exec -- git add kubernetes/apps/media/encode-benchmark kubernetes/apps/media/kustomization.yaml scripts/validate/encode-benchmark.sh
mise exec -- git commit -m "feat(media): add inert encoding benchmark sources"
```

### Task 3: Implement Metadata, Lifecycle, and Census Contracts Test-First

**Files:**
- Create: `kubernetes/apps/media/encode-benchmark/app/scripts/probe.sh`
- Create: `kubernetes/apps/media/encode-benchmark/app/scripts/census.sh`
- Modify: `kubernetes/apps/media/encode-benchmark/app/kustomization.yaml`
- Create: `scripts/encode-benchmark/torrent-inventory.py`
- Create: `kubernetes/apps/media/encode-benchmark/tests/fixtures/media/avc-8bit.mkv`
- Create: `kubernetes/apps/media/encode-benchmark/tests/fixtures/media/hdr10-hevc-10bit.mkv`
- Create: `kubernetes/apps/media/encode-benchmark/tests/fixtures/ffprobe/{vc1,dolby-vision-profile7,multi-audio,truehd-unknown}.json`
- Create: `kubernetes/apps/media/encode-benchmark/tests/fixtures/qbittorrent/*.json`
- Create: `kubernetes/apps/media/encode-benchmark/tests/golden/census.csv`
- Create: `kubernetes/apps/media/encode-benchmark/tests/golden/audio-inventory.csv`
- Create: `kubernetes/apps/media/encode-benchmark/tests/census.bats`

**Interfaces:**
- `probe.sh <source-path>` emits one compact JSON object with normalized video/container/count fields and an `audioTracks` array.
- `torrent-inventory.py` emits tab-separated `inode`, `lifecycle_state`, `torrent_hash`, `category`, and comma-sorted `tags`; it never emits credentials or announce URLs.
- `census.sh <torrent-state.tsv> <output-directory>` emits `census.csv` and `audio-inventory.csv` atomically.

- [ ] **Step 1: Add real-media and metadata-fixture failing tests**

Generate two tiny real media fixtures using the pinned FFmpeg toolchain:

```bash
mise exec -- ffmpeg -v error -f lavfi -i 'color=c=black:s=1920x1080:r=24' \
  -frames:v 2 -c:v libx264 -preset ultrafast -crf 51 -an \
  kubernetes/apps/media/encode-benchmark/tests/fixtures/media/avc-8bit.mkv
mise exec -- ffmpeg -v error -f lavfi -i 'color=c=black:s=3840x2160:r=24' \
  -frames:v 2 -c:v libx265 -preset ultrafast -crf 51 -pix_fmt yuv420p10le \
  -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc -an \
  kubernetes/apps/media/encode-benchmark/tests/fixtures/media/hdr10-hevc-10bit.mkv
find kubernetes/apps/media/encode-benchmark/tests/fixtures/media -type f -size +500k -print
```

Expected: both files probe successfully and the final command prints nothing. Invoke the real pinned `ffprobe` against these files in Bats and assert AVC/HDR cohort, codec, resolution, pixel format, bit depth, and HDR metadata.

Provide documented ffprobe JSON fixtures for VC-1, DV Profile 7, multi-audio, and unknown TrueHD bitrate. VC-1 and DV Profile 7 are parser-only metadata fixtures because pinned FFmpeg cannot reproducibly synthesize conformant tiny sources for those formats; the later guarded capability/library workflow must prove the detection-only DV skip against real library media. Provide qBittorrent fixtures covering uploading public, stopped public, uploading CZTeam, stopped CZTeam, and an unmatched hardlink.

For metadata-only cases, the Bats test prepends a fixture-selecting stub `ffprobe` to `PATH`, creates fixture filenames and hardlinks under a temporary `/media` analogue, then asserts exact golden CSV equality. Include assertions:

```bash
run "$SCRIPTS/census.sh" "$FIXTURES/qbittorrent/inodes.tsv" "$output_dir"
[ "$status" -eq 0 ]
run diff -u "$GOLDEN/census.csv" "$output_dir/census.csv"
[ "$status" -eq 0 ]
run diff -u "$GOLDEN/audio-inventory.csv" "$output_dir/audio-inventory.csv"
[ "$status" -eq 0 ]
```

Run and expect FAIL because the scripts do not yet produce the schemas.

- [ ] **Step 2: Implement normalized probing**

Use `ffprobe -v error -show_streams -show_format -show_chapters -of json` only. Do not use packet-counting flags. Normalize these keys:

```text
path,sizeBytes,durationSeconds,container,videoCodec,width,height,pixelFormat,
bitDepth,colorPrimaries,colorTransfer,colorSpace,hdrFormat,dolbyVisionProfile,
videoBitRate,frameRate,audioTrackCount,subtitleCount,chapterCount,audioTracks
```

Classify cohorts in this order: DV Profile 7 → `dolby-vision`; HEVC 10-bit with `smpte2084`/`bt2020` → `hdr10`; VC-1 → `vc1`; AVC → `avc`; otherwise `other`. Audio bytes use `reported` when the stream has a numeric `bit_rate`, `estimated` when Matroska exposes a numeric per-stream `BPS` calculated-statistics tag, and `unknown` otherwise; compute bytes as rate × duration ÷ 8 and never allocate the container's aggregate bit rate across tracks.

Replace only the `probe.sh` and `census.sh` ConfigMap file mappings with `scripts/probe.sh` and `scripts/census.sh`; leave `runmeta.sh`, `benchmark.sh`, and `stills.sh` mapped to the shared fail-closed scaffold.

- [ ] **Step 3: Implement the read-only qBittorrent inode bridge**

The Python program imports `qbittorrentapi` already present in the qbit_manage image, authenticates using `QBT_USER` and `QBT_PASS`, reads only movie-category torrents and their file lists, and stats their download-side paths under `/data/downloads`. Lifecycle precedence is:

```python
if torrent.state not in {"stoppedUP", "pausedUP"}:
    state = "active"
elif "tracker-private" in tags or "tracker-czteam" in tags:
    state = "private-permanent"
else:
    state = "public-awaiting-cleanup"
```

When more than one torrent maps to an inode, choose `active` over `private-permanent` over `public-awaiting-cleanup`. `census.sh` maps `st_nlink == 1` to `unlinked`; a hardlink absent from the inode export maps conservatively to `active` with `lifecycle_evidence=unmatched-hardlink`, preserving the four-state schema and the fail-safe skip semantics.

- [ ] **Step 4: Implement atomic census outputs**

Write temporary files in the target directory and rename only after the walk succeeds. Sort rows by bytewise source path. Use these exact headers:

```text
census.csv:
source_path,source_size_bytes,link_count,lifecycle_state,lifecycle_evidence,torrent_hash,torrent_category,torrent_tags,cohort,container,duration_seconds,video_codec,width,height,pixel_format,bit_depth,color_primaries,color_transfer,color_space,hdr_format,dolby_vision_profile,video_bit_rate,frame_rate,audio_track_count,subtitle_count,chapter_count,audio_bytes_total,audio_bytes_method

audio-inventory.csv:
source_path,track_index,codec,channels,channel_layout,language,bit_rate,duration_seconds,audio_bytes,audio_bytes_method
```

CSV-escape every string field using doubled quotes. Reject any input path outside `/media` in production; allow `BENCHMARK_MEDIA_ROOT` only when `BENCHMARK_TEST_MODE=1` for Bats.

- [ ] **Step 5: Run focused and source validation**

```bash
mise exec -- bats kubernetes/apps/media/encode-benchmark/tests/census.bats
mise exec -- just kube encode-benchmark-validate
```

Expected: exact golden CSV matches; shell formatting and static analysis pass.

- [ ] **Step 6: Commit the census unit**

```bash
mise exec -- git add kubernetes/apps/media/encode-benchmark/app/kustomization.yaml kubernetes/apps/media/encode-benchmark/app/scripts/probe.sh kubernetes/apps/media/encode-benchmark/app/scripts/census.sh kubernetes/apps/media/encode-benchmark/tests scripts/encode-benchmark/torrent-inventory.py
mise exec -- git commit -m "feat(media): add movie census harness"
```

### Task 4: Implement Immutable Run Identity and Exact Resume

**Files:**
- Create: `kubernetes/apps/media/encode-benchmark/app/scripts/runmeta.sh`
- Modify: `kubernetes/apps/media/encode-benchmark/app/kustomization.yaml`
- Create: `kubernetes/apps/media/encode-benchmark/tests/fixtures/manifests/*.json`
- Create: `kubernetes/apps/media/encode-benchmark/tests/runmeta.bats`

**Interfaces:**
- `runmeta.sh create <mode> [run-id]` writes `manifest.json` and prints the run ID.
- `runmeta.sh verify <run-id>` exits `0` only for an exact identity match and prints a redacted field diff on mismatch.
- `runmeta.sh completed <run-id> <row-key>` exits `0` when an already-successful results row has the exact key.

- [ ] **Step 1: Write the resume failures first**

Cover three cases with a fixed clock and fixture environment:

```bash
setup() {
  export BENCHMARK_TEST_MODE=1
  export BENCHMARK_NOW=20260802T120000Z
  export BENCHMARK_OUT="$BATS_TEST_TMPDIR/out"
  export BENCHMARK_IDENTITY_FIXTURE="$BATS_TEST_DIRNAME/fixtures/manifests/identity.json"
  mkdir -p "$BENCHMARK_OUT/runs"
}

@test "no run id always creates a fresh timestamped identity" {
  run "$SCRIPTS/runmeta.sh" create quality
  [ "$status" -eq 0 ]
  first="$output"
  export BENCHMARK_NOW=20260802T120001Z
  run "$SCRIPTS/runmeta.sh" create quality
  [ "$status" -eq 0 ]
  [ "$output" != "$first" ]
}

@test "matching explicit run id resumes and skips a completed row" {
  run_id="$($SCRIPTS/runmeta.sh create quality)"
  printf '%s\n' 'quality|abc123|detail|qsv|22,passed' >"$BENCHMARK_OUT/runs/$run_id/results.csv"
  run "$SCRIPTS/runmeta.sh" verify "$run_id"
  [ "$status" -eq 0 ]
  run "$SCRIPTS/runmeta.sh" completed "$run_id" 'quality|abc123|detail|qsv|22'
  [ "$status" -eq 0 ]
}

@test "changed script digest aborts explicit resume" {
  run_id="$($SCRIPTS/runmeta.sh create quality)"
  export BENCHMARK_IDENTITY_FIXTURE="$BATS_TEST_DIRNAME/fixtures/manifests/changed-script.json"
  run "$SCRIPTS/runmeta.sh" verify "$run_id"
  [ "$status" -eq 1 ]
  [[ "$output" == *'scriptDigests.benchmark.sh'* ]]
  [ "$(find "$BENCHMARK_OUT/runs" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" -eq 1 ]
}
```

The third case must expect status `1`, a diff naming `scriptDigests.benchmark.sh`, no changed manifest bytes, and no second run directory.

- [ ] **Step 2: Define and implement canonical identity**

Build canonical JSON with sorted keys and these fields:

```json
{
  "schemaVersion": 1,
  "mode": "quality",
  "imageDigest": "sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb",
  "scriptDigests": {},
  "samplesDigest": "sha256:9f4e2b20cfb4eaf89f18ba1a3f706d384c450f65a150df41d4e5d50b957f829e",
  "sources": [],
  "encoderCommands": [],
  "node": {"name": "", "kernel": "", "i915": "", "vpl": ""},
  "vmaf": {"model": "vmaf_4k_v0.6.1", "version": ""},
  "savingsSeed": 20260802,
  "clientDevice": null
}
```

Each source entry contains path, size, and SHA-256. Generate a new ID as `YYYYMMDDTHHMMSSZ-<first8(identity-sha256)>`; create the run directory with `mkdir`, write `manifest.json.tmp` using `umask 022`, fsync by closing the file, then rename once. Make the file mode `0444`. Resume recomputes identity while ignoring only the original creation timestamp; every listed identity field must match.

Use row key `panel|source_sha256|clip_id|encoder|setting`. Only rows with `status=passed` are resumable; failed/invalid rows rerun and append a new attempt number.

Replace the `runmeta.sh` ConfigMap file mapping with `scripts/runmeta.sh`; leave `benchmark.sh` and `stills.sh` mapped to the shared fail-closed scaffold.

- [ ] **Step 3: Prove identity behavior and commit**

```bash
mise exec -- bats kubernetes/apps/media/encode-benchmark/tests/runmeta.bats
mise exec -- just kube encode-benchmark-validate
mise exec -- git add kubernetes/apps/media/encode-benchmark/app/kustomization.yaml kubernetes/apps/media/encode-benchmark/app/scripts/runmeta.sh kubernetes/apps/media/encode-benchmark/tests
mise exec -- git commit -m "feat(media): make benchmark runs immutable and resumable"
```

### Task 5: Implement Encode, Measurement, Validation, and Still Generation

**Files:**
- Create: `kubernetes/apps/media/encode-benchmark/app/scripts/benchmark.sh`
- Create: `kubernetes/apps/media/encode-benchmark/app/scripts/stills.sh`
- Modify: `kubernetes/apps/media/encode-benchmark/app/kustomization.yaml`
- Modify: `scripts/validate/encode-benchmark.sh`
- Delete: `kubernetes/apps/media/encode-benchmark/app/scripts/not-ready.sh`
- Create: `kubernetes/apps/media/encode-benchmark/tests/fixtures/logs/*.log`
- Create: `kubernetes/apps/media/encode-benchmark/tests/fixtures/metrics/*.json`
- Create: `kubernetes/apps/media/encode-benchmark/tests/golden/results.csv`
- Create: `kubernetes/apps/media/encode-benchmark/tests/benchmark.bats`
- Create: `kubernetes/apps/media/encode-benchmark/tests/stills.bats`

**Interfaces:**
- `benchmark.sh capabilities` proves the runtime image and a real five-second QSV encode.
- `benchmark.sh quality [run-id]` performs lossless clip extraction, QSV sweep, x265 bracketing sweep, measurements, validation, and stills.
- `benchmark.sh savings <run-id>` full-encodes the savings panel using committed chosen settings.
- `benchmark.sh finalist <run-id> <sample-id>` copies only an explicitly selected full encode to `encodes/`.
- `benchmark.sh findings <run-id>` combines named quality, savings, and contention inputs into run-scoped Markdown without exposing credentials.
- `stills.sh <source> <encoded> <timestamp> <destination-prefix>` emits matched source/variant PNGs.

- [ ] **Step 1: Write failing parser, decision, and output tests**

Fixture logs must include LA-ICQ, a fallback rate-control mode, successful QSV device initialization, failed initialization, non-zero and zero DRM engine counters. Metrics fixtures must test VMAF harmonic mean, 1% low, median/IQR, x265 interpolation, and unbracketed results.

Assert the exact `results.csv` header:

```text
run_id,panel,sample_id,cohort,source_sha256,clip_id,encoder,requested_setting,selected_rate_control,status,attempt,input_bytes,output_bytes,reduction_percent,input_bit_rate,output_bit_rate,wall_seconds,encode_fps,encode_speed,vmaf_harmonic_mean,vmaf_1pct_low,ssim,gpu_busy_percent,qsv_proof,validation_codec,validation_duration,validation_resolution,validation_frame_rate,validation_bit_depth,validation_hdr,validation_audio_tracks,validation_subtitle_tracks,validation_chapters,validation_failures,log_path,output_disposition
```

- [ ] **Step 2: Implement capability mode**

Capability mode must fail unless all are true:

```bash
ffmpeg -hide_banner -encoders | rg -q 'hevc_qsv'
ffmpeg -hide_banner -filters | rg -q 'libvmaf'
ffmpeg -hide_banner -encoders | rg -q 'libx265'
command -v sh awk jq stat sha256sum ffprobe
test "$(id -u)" = 568
```

Generate a five-second `testsrc2` clip in scratch, initialize `qsv=hw:/dev/dri/renderD128`, encode HEVC QSV, decode the result to null, run one libvmaf score against the source, and record versions plus the Kubernetes image ID. The capability result printed to stdout is compact JSON and contains no media paths.

- [ ] **Step 3: Implement exact clip and sweep commands**

Extract each clip with stream copy:

```bash
ffmpeg -v error -ss "$timestamp" -i "$source" -t 90 -map 0 -c copy "$clip"
```

QSV uses verbose logging and the requested LA-ICQ controls:

```bash
ffmpeg -v verbose -init_hw_device qsv=hw:/dev/dri/renderD128 -filter_hw_device hw \
  -i "$clip" -map 0 -c:v hevc_qsv -preset veryslow \
  -global_quality "$gq" -look_ahead 1 -extbrc 1 \
  -c:a copy -c:s copy -map_metadata 0 -map_chapters 0 "$output"
```

x265 uses `-c:v libx265 -preset slow -crf "$crf"`, copies non-video streams and metadata, and starts at `18 20 22 24`. Extend by steps of `2` on only the side needed until the QSV VMAF lies inside the measured x265 VMAF range; stop at CRF `10` or `34` and emit `unbracketed` rather than extrapolating.

- [ ] **Step 4: Implement objective measurements and QSV proof**

Run VMAF with model `vmaf_4k_v0.6.1`, JSON logging, and source as the reference input. Compute harmonic mean as `count / sum(1/max(score,0.000001))`; compute the 1% low as the mean of the lowest `max(1,ceil(frame_count*0.01))` frame scores. Run SSIM separately and capture its `All` value.

For matched-VMAF x265 comparison, choose adjacent measured x265 points `(v1,b1)` and `(v2,b2)` with `v1 <= qsv_vmaf <= v2`, calculate `matched_bitrate = b1 + (qsv_vmaf-v1)*(b2-b1)/(v2-v1)`, then calculate premium as `(qsv_bitrate-matched_bitrate)*100/matched_bitrate`. Equal-VMAF points use their measured bitrate directly.

Sample `/sys/class/drm/card*/engine/*/busy` once per second while ffmpeg runs. Mark `qsv_proof=passed` only when hardware initialization succeeds, the parsed selected mode is `LA-ICQ`, and video-engine busy delta is non-zero. Mark zero utilization, absent telemetry, unexpected 4K speed outside `0.5x..2.0x`, or unexpected 1080p speed outside `2x..20x` as `suspect`; suspect rows cannot become eligible.

- [ ] **Step 5: Implement the output validation chain**

Decode the entire output to null, then compare normalized source/output probes. Validation columns independently check:

- codec is HEVC;
- duration differs by no more than `1.0` second for clips or `2.0` seconds for full titles;
- width/height and rational frame rate match;
- bit depth matches and HDR10 remains 10-bit;
- HDR color primaries/transfer/matrix and mastering/max-CLL metadata match;
- audio, subtitle, and chapter counts match.

Record every failed field in `validation_failures` separated by `;`; append the row and continue to the next variant. Never copy an invalid output to `/out`.

- [ ] **Step 6: Implement full-title disposition and stills**

Savings encodes run at the committed `chosenSettings.<cohort>`. During the full-file pass, run `ffprobe -show_packets -select_streams a -show_entries packet=stream_index,size -of csv=p=0`, sum packet sizes per stream, and append `packet-counted` rows to the run's `audio-inventory.csv`; then append measurements and delete the scratch output. `finalist` re-encodes one named sample at that setting and copies it only after validation passes and the operator provides `ENCODE_BENCHMARK_FINALIST_CONFIRM='copy:encode-benchmark:<run-id>:<sample-id>'`.

For each quality variant, create 1:1 PNG source/encoded crops at the matched timestamp with filenames `<sample>-<clip>-<encoder>-<setting>-{source,encoded}.png`. Preserve no intermediate video.

- [ ] **Step 7: Replace the final scaffold mappings**

Replace the `benchmark.sh` and `stills.sh` ConfigMap file mappings with `scripts/benchmark.sh` and `scripts/stills.sh`. Once all five real scripts exist and the rendered ConfigMap contains all five keys, delete `scripts/not-ready.sh`. Tighten `scripts/validate/encode-benchmark.sh` to require the five real script files and reject any remaining scaffold file or `not-ready.sh` mapping.

- [ ] **Step 8: Run focused tests and commit**

```bash
mise exec -- bats kubernetes/apps/media/encode-benchmark/tests/benchmark.bats kubernetes/apps/media/encode-benchmark/tests/stills.bats
mise exec -- just kube encode-benchmark-validate
mise exec -- git add kubernetes/apps/media/encode-benchmark/app/kustomization.yaml kubernetes/apps/media/encode-benchmark/app/scripts kubernetes/apps/media/encode-benchmark/tests scripts/validate/encode-benchmark.sh
mise exec -- git commit -m "feat(media): add QSV benchmark measurement engine"
```

### Task 6: Add Guarded Rendering, Preflight, Dispatch, Results, and Cleanup

**Files:**
- Create: `scripts/encode-benchmark/preflight.sh`
- Create: `scripts/encode-benchmark/dispatch.sh`
- Create: `scripts/encode-benchmark/results.sh`
- Create: `scripts/encode-benchmark/select-samples.sh`
- Create: `scripts/verify/encode-benchmark.sh`
- Create: `kubernetes/apps/media/encode-benchmark/tests/dispatch.bats`
- Create: `kubernetes/apps/media/encode-benchmark/tests/selection.bats`
- Modify: `kubernetes/mod.just:952`

**Interfaces:**
- `encode-benchmark-preflight` is API-read-only and identifies eligible non-Plex GPU nodes and actual free NVMe.
- `encode-benchmark-capabilities`, `-census`, and `-run <quality|savings|finalist|contention-a|contention-b|contention-c|contention-d> [run-id] [sample-id]` create run-scoped resources only after exact confirmation and deployed-source checks. `encode-benchmark-finalist` is a thin alias that forwards its run/sample arguments to the shared `-run finalist` recipe, so it adds no second rollout guard.
- `encode-benchmark-results <run-id>` reads Job state/log summaries only.
- `encode-benchmark-clean <run-id>` deletes exactly one share run tree via a short-lived cleanup Job.

- [ ] **Step 1: Test every confirmation guard before implementation**

Use PATH-stubbed `kubectl`, `git`, and `flux` commands. For capabilities, census, run, finalist, and clean, test absent, empty, wrong, and exact tokens. The stubs must record zero `create`, `apply`, `delete`, or `exec` calls until the exact token passes.

Exact tokens are:

```text
ENCODE_BENCHMARK_CAPABILITIES_CONFIRM=run:encode-benchmark:capabilities
ENCODE_BENCHMARK_CENSUS_CONFIRM=run:encode-benchmark:census
ENCODE_BENCHMARK_RUN_CONFIRM=run:encode-benchmark:<mode>
ENCODE_BENCHMARK_FINALIST_CONFIRM=copy:encode-benchmark:<run-id>:<sample-id>
ENCODE_BENCHMARK_CLEAN_CONFIRM=delete:encode-benchmark:<run-id>
```

In `selection.bats`, feed a fixed census fixture in two different row orders to `select-samples.sh <census.csv> <seed> <local-movie-root>`; assert identical YAML, exact seed `20260802`, unique sample IDs, representation from every populated bitrate quartile, and eight entries for each cohort with at least eight eligible rows. The script maps each `/media/<relative-path>` census path to `<local-movie-root>/<relative-path>` only for size/hash verification and preserves the pod path in YAML. Do not filter by lifecycle state: active public titles can become eligible after cleanup, while lifecycle weighting is applied when findings estimate recoverable space.

- [ ] **Step 2: Implement read-only cluster preflight**

Require `.kube/config` and the production API VIP. Read the Plex pod's node, node allocatable i915 counts, PVC state, Kustomization readiness, and `/api/v1/nodes/<node>/proxy/stats/summary`. An eligible node is not the Plex node, advertises one free i915 slot, and has at least `200Gi` `node.fs.availableBytes`. Print every candidate and why it passed/failed; pass when at least one candidate passes. Do not select or pin the Job to the measured node, preserving the accepted placement behavior.

The Job entrypoint repeats fail-closed checks for `/media` readability, `/out` create/remove, sample size/hash, QSV/libvmaf/libx265, and image identity before the first encode.

- [ ] **Step 3: Render Jobs without applying the template through Flux**

`dispatch.sh` runs `kustomize build`, extracts the generated scripts ConfigMap name, loads the image and panel data from the samples ConfigMap source, copies the template to a temporary directory, and uses `yq -i` to set:

- Job name `encode-benchmark-<mode>-<run-key>`;
- ownership labels and annotations;
- container image, command, and optional explicit run ID;
- scripts ConfigMap name;
- mode-specific volumes/resources.

For `capabilities`, keep GPU and scratch but omit media/out. For `census`, remove GPU, anti-affinity, scratch, and ephemeral-storage resources; retain media/out and add the transient inode ConfigMap. For cleanup, mount only `/out`, remove GPU/anti-affinity/scratch/media, and run `rm -rf -- "/out/runs/$run_id"` only after regex `^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$` and exact confirmation checks.

- [ ] **Step 4: Preserve the no-downloads-mount invariant while joining lifecycle state**

The census dispatcher runs the committed Python bridge through `kubectl exec -i deployment/qbit-manage -- python -`, capturing only its TSV stdout in a mode-`0600` temporary file. Create the census Job initially suspended, read its UID, create a ConfigMap containing the TSV with an ownerReference to that Job, then unsuspend the Job. The qbit_manage pod already mounts downloads; the benchmark Job never does. Abort and delete the suspended Job if inventory generation or ConfigMap ownership fails.

- [ ] **Step 5: Implement mode behavior and read-only results**

`quality` and `savings` use one GPU Job. Contention modes create either one 4K worker (`a`) or two 1080p workers (`b`–`d`) with unique worker labels and separate CSV fragments; no pod may schedule with Plex. `results.sh` validates the run ID, selects only Jobs with the exact ownership label, prints phase/succeeded/failed/start/completion/node information and sanitized final log summary, and prints `/out/runs/<run-id>` as the artifact location. It never prints manifest source paths or hashes.

`verify/encode-benchmark.sh` proves Kustomization Ready and unsuspended when activated, PriorityClass/ConfigMaps/PrometheusRule present, no persistent benchmark workload exists, and no benchmark pod is co-resident with Plex.

- [ ] **Step 6: Add the exact `kubernetes/mod.just` surface**

Recipes call the focused scripts and use `source scripts/lib/rollout.sh; require_deployed_source` for capabilities, census, and run. Keep preflight, verify, and results read-only. Keep clean run-ID scoped and confirmation-only because it removes run data rather than rolling out Git source.

Run:

```bash
mise exec -- bats kubernetes/apps/media/encode-benchmark/tests/dispatch.bats kubernetes/apps/media/encode-benchmark/tests/selection.bats
mise exec -- just kube encode-benchmark-validate
```

Expected: every refusal test passes and no live command runs during Bats.

- [ ] **Step 7: Commit guarded operations**

```bash
mise exec -- git add scripts/encode-benchmark scripts/verify/encode-benchmark.sh kubernetes/mod.just kubernetes/apps/media/encode-benchmark/tests/dispatch.bats
mise exec -- git commit -m "feat(media): guard encoding benchmark operations"
```

### Task 7: Add Bootstrap, CI Catalog Registration, and Full Offline Validation

**Files:**
- Modify: `.just/bootstrap.just:2635`
- Modify: `.just/repository.just:1194`
- Modify: `tests/catalog.yaml:6-40,182-318,318-430`
- Modify: `kubernetes/mod.just`
- Create: `kubernetes/apps/media/encode-benchmark/tests/bootstrap.bats`

**Interfaces:**
- `mise exec -- just bootstrap encode-benchmark` is the only rollout entrypoint.
- `validation.encode-benchmark` runs in `just ci`.
- `verification.encode-benchmark` is operator-owned and read-only.

- [ ] **Step 1: Test bootstrap refusal and failure re-suspension**

The Bats test must prove:

- missing/wrong `ENCODE_BENCHMARK_BOOTSTRAP_CONFIRM` never resumes Flux;
- live Kustomization not suspended is refused;
- source Kustomization not suspended is refused for the initial rollout;
- a failed verify after resume invokes `flux suspend kustomization encode-benchmark`;
- successful verification leaves it resumed and prints the activation handoff.

- [ ] **Step 2: Add the bootstrap recipe**

Use exact confirmation `ENCODE_BENCHMARK_BOOTSTRAP_CONFIRM='bootstrap:media:encode-benchmark'`. Follow the existing qbit_manage cleanup-trap pattern. `require_deployed_source` includes `.just/bootstrap.just`, `kubernetes/mod.just`, all encode-benchmark source/tests/helpers, `scripts/lib/rollout.sh`, `tests/catalog.yaml`, and `kubernetes/apps/media/kustomization.yaml`.

The recipe validates source, reconciles Flux source and `cluster-apps`, confirms the live child is suspended, resumes it, waits Ready, runs `encode-benchmark-verify`, then says to run capabilities. On any post-resume failure, re-suspend while preserving inert resources.

- [ ] **Step 3: Register CI and verification**

Add `validation.encode-benchmark` immediately after `validation.intel-gpu-plugin` in `executions.ci` and suite definitions:

```yaml
- metadata: {id: validation.encode-benchmark, source: validation, framework: bats, suite: ci, tier: offline, target: encode-benchmark, scenario: source, scope: application, intent: regression, mutates_cluster: false, execution_owner: shared}
  confirmation: {type: none, variable: null, expected: null}
  runner: {command: "mise exec -- just kube encode-benchmark-validate", implementation: scripts/validate/encode-benchmark.sh}
  native_results: {strategy: wrapper-junit}
```

Add `verification.encode-benchmark` after `verification.intel-gpu-plugin` and to the verification campaign, with command `mise exec -- just kube encode-benchmark-verify`, `mutates_cluster: false`, and `execution_owner: human`.

- [ ] **Step 4: Update repository guard accounting**

Capabilities, census, and run add three `require_deployed_source` invocations, and bootstrap adds one. Change the exact count assertion in `.just/repository.just` from `24` to `28` after confirming with:

```bash
mise exec -- rg -c 'require_deployed_source ' .just/bootstrap.just kubernetes/mod.just
```

Expected summed count: `28`.

- [ ] **Step 5: Run the complete PR 1 gate**

```bash
mise exec -- just kube encode-benchmark-validate
mise exec -- just repo lint
mise exec -- just ci
mise exec -- git status --short
```

Expected: every command exits `0`; only intended source and plan changes are present.

- [ ] **Step 6: Commit the workflow integration**

```bash
mise exec -- git add .just/bootstrap.just .just/repository.just kubernetes/mod.just tests/catalog.yaml kubernetes/apps/media/encode-benchmark/tests/bootstrap.bats
mise exec -- git commit -m "test(media): gate encoding benchmark workflows"
```

### Task 8: Deliver PR 1 and Prove the Runtime Image on Real Hardware

**Files:**
- No source change until capability evidence is returned.

**Interfaces:**
- Consumes: PR 1 commits and operator authorization.
- Produces: A passed capability Job with image ID, node, QSV encode proof, libvmaf score, libx265, shell/tool, ffprobe, and UID evidence.

- [ ] **Step 1: Rebase and validate immediately before push**

```bash
mise exec -- git status --short --branch
mise exec -- git fetch origin
mise exec -- git rebase origin/main
mise exec -- just ci
mise exec -- git push -u origin fileflows-movie-encoding-strategy
```

Expected: clean branch, successful rebase if needed, green CI, and no direct update to `main`.

- [ ] **Step 2: Open PR 1 and stop at the merge boundary**

Open a PR describing the inert resources, read-only source mount, no TV/download mount, candidate image status, guarded commands, tests, and remaining operator gates. Do not merge or enable auto-merge without explicit authorization for this PR.

- [ ] **Step 3: Operator bootstraps the inert sources after merge**

Operator command:

```bash
ENCODE_BENCHMARK_BOOTSTRAP_CONFIRM='bootstrap:media:encode-benchmark' \
  mise exec -- just bootstrap encode-benchmark
```

Expected: Flux child Ready, only ConfigMaps/PriorityClass/PrometheusRule exist, and no Job runs automatically.

- [ ] **Step 4: Operator runs read-only placement preflight and the capability Job**

```bash
mise exec -- just kube encode-benchmark-preflight
ENCODE_BENCHMARK_CAPABILITIES_CONFIRM='run:encode-benchmark:capabilities' \
  mise exec -- just kube encode-benchmark-capabilities
```

Expected: at least one non-Plex node has a free i915 slot and `>=200Gi` free; the Job runs as UID 568 and returns all capability booleans true plus a real five-second QSV encode and libvmaf result. If any capability is false, stop before census and commit a newly selected immutable runtime arrangement for review.

### Task 9: Run the Census and Pin Reproducible Panels in PR 2

**Files:**
- Modify: `kubernetes/apps/media/encode-benchmark/app/samples.yaml`
- Modify: `kubernetes/apps/media/encode-benchmark/ks.yaml`

**Interfaces:**
- Consumes: Passed capability output and `/out/census.csv` plus `/out/audio-inventory.csv`.
- Produces: Verified runtime evidence; seven fixed quality entries; seeded, bitrate-stratified savings entries; activated but still inert Flux sources.

- [ ] **Step 1: Record verified capability evidence**

Change `capabilityStatus` to `verified` and record exact Job output under:

```yaml
capabilityEvidence:
  digestResolvable: true
  hevcQsv: true
  realQsvEncode: true
  libvmaf4k: true
  libx265: true
  shellTools: true
  ffprobe: true
  nonRootUid568: true
  verifiedAt: <UTC timestamp emitted by the Job>
  nodeName: <node emitted by the Job>
  imageId: <containerStatuses imageID emitted by the recipe>
```

Use the emitted values exactly; do not fabricate or manually shorten the image ID.

- [ ] **Step 2: Run the guarded census**

Before the first census, the operator creates the share-root directory `benchmark` in the UNAS UI and confirms it is owned/writable by UID/GID `568`. This is the only share-root setup action; Jobs still receive only `subPath: benchmark`, never the share root. If the directory already exists, inspect it and leave existing run directories untouched.

```bash
ENCODE_BENCHMARK_CENSUS_CONFIRM='run:encode-benchmark:census' \
  mise exec -- just kube encode-benchmark-census
mise exec -- just kube encode-benchmark-results <census-run-id>
```

Expected: one metadata-only row per movie, a separate audio row per track, no GPU request, and four lifecycle states with unmatched hardlinks conservatively active.

- [ ] **Step 3: Generate the seeded savings panel**

On the operator workstation with the benchmark share mounted, run:

```bash
mise exec -- scripts/encode-benchmark/select-samples.sh \
  /Volumes/Prometheus/benchmark/runs/<census-run-id>/census.csv \
  20260802 /Volumes/Prometheus/media/movies
```

The script divides AVC, VC-1, and HDR10 cohorts into source-bitrate quartiles and uses a deterministic SHA-256 ordering of `seed|source_path` to select about eight per major cohort while spanning every populated quartile. It prints a complete `savingsPanel` YAML list with sample ID, cohort, an absolute path below `/media/`, source size, and source SHA-256.

- [ ] **Step 4: Add the operator-selected quality panel**

Choose exactly seven entries from the census and record:

1. 1080p VC-1.
2. 1080p AVC `>=30 Mb/s`, clean.
3. 1080p AVC `>=30 Mb/s`, grain-heavy.
4. 4K HDR10, clean modern digital.
5. 4K HDR10, grain-heavy film.
6. 4K HDR10, dark/high-motion.
7. Dolby Vision Profile 7 with `detectionOnly: true`.

Each of entries 1–6 has three named timestamps `detail`, `dark`, and `motion` in `HH:MM:SS.mmm`; entry 7 has no clips and is never encoded. Every entry includes the exact path, size, and SHA-256 from a full source hash performed once during selection.

- [ ] **Step 5: Persist inert activation**

Set `spec.suspend: false` in `ks.yaml`. This activates only ConfigMaps, PriorityClass, and PrometheusRule; no Job is declared.

Run:

```bash
mise exec -- just kube encode-benchmark-validate
mise exec -- just ci
mise exec -- git add kubernetes/apps/media/encode-benchmark/app/samples.yaml kubernetes/apps/media/encode-benchmark/ks.yaml
mise exec -- git commit -m "feat(media): pin encoding benchmark panels"
```

- [ ] **Step 6: Push PR 2 safely and stop at its merge boundary**

```bash
mise exec -- git fetch origin
mise exec -- git rebase origin/main
mise exec -- just ci
mise exec -- git push
```

Open PR 2 with cohort counts, lifecycle totals, selected image evidence, sample-selection seed, and explicit note that activation remains workload-free. Do not merge without specific authorization.

### Task 10: Run Quality, Record Visual Decisions, and Commit Winning Settings

**Files:**
- Modify: `kubernetes/apps/media/encode-benchmark/app/samples.yaml`

**Interfaces:**
- Consumes: PR 2 on `origin/main`, pinned quality panel, QSV/x265 measurements, PNG stills, and temporary Plex finalist review.
- Produces: One eligible winning QSV setting per viable cohort in `chosenSettings`.

- [ ] **Step 1: Run the quality panel**

```bash
mise exec -- just kube encode-benchmark-preflight
ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:quality' \
  mise exec -- just kube encode-benchmark-run quality
mise exec -- just kube encode-benchmark-results <quality-run-id>
```

Expected: 90 QSV clip encodes for six encoded titles, x265 sweeps on grain-heavy AVC/HDR10 clips extended only to bracket QSV, DV detected and skipped, and no persistent clip outputs.

- [ ] **Step 2: Triage stills and review finalists in Plex**

Review all passing source/variant PNG pairs at 1:1. For each cohort, mark every variant `PASS` or `FAIL`; never infer visual approval from VMAF. Copy only finalists with the run/sample-bound confirmation recipe, add `/Volumes/Prometheus/benchmark/runs/<run-id>/encodes` as a temporary Plex library in the UI, and verify motion, Direct Play, and HDR on the designated physical client. Remove the temporary library afterward; accept bounded thumbnail residue on Plex's config PVC.

- [ ] **Step 3: Select settings mechanically**

For each cohort, filter to variants where every individual clip passes all §11.1 thresholds and operator visual review. Choose the eligible setting with the largest measured size reduction. Record:

```yaml
chosenSettings:
  avc: {globalQuality: <winning integer>, qualityRunId: <exact run-id>}
  vc1: {globalQuality: <winning integer>, qualityRunId: <exact run-id>}
  hdr10: {globalQuality: <winning integer>, qualityRunId: <exact run-id>}
```

Omit a cohort with no eligible setting and record its NO-GO in the final findings. Values must be one of `20`, `22`, `24`, `26`, or `28` and must cite the exact quality run.

- [ ] **Step 4: Validate, commit, and deliver the settings change**

```bash
mise exec -- just kube encode-benchmark-validate
mise exec -- just ci
mise exec -- git add kubernetes/apps/media/encode-benchmark/app/samples.yaml
mise exec -- git commit -m "feat(media): record approved QSV cohort settings"
mise exec -- git fetch origin
mise exec -- git rebase origin/main
mise exec -- just ci
mise exec -- git push
```

Open PR 3 with per-clip threshold evidence and visual decisions. Do not merge without explicit authorization. The operator must merge PR 3 before savings execution because `encode-benchmark-run` verifies its implementation and chosen-settings source against `origin/main`.

### Task 11: Measure Savings and Plex Contention, Then Publish the Decision

**Files:**
- Create: `docs/decisions/YYYY-MM-DD-fileflows-movie-encoding-findings.md`

**Interfaces:**
- Consumes: Merged chosen settings, savings panel results, x265 comparison, Plex contention observations, NAS uplink speed, and operator review.
- Produces: Per-cohort GO/MARGINAL/NO-GO decision and measured FileFlows scope; no FileFlows deployment.

- [ ] **Step 1: Run full-title savings**

```bash
mise exec -- just kube encode-benchmark-preflight
ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:savings' \
  mise exec -- just kube encode-benchmark-run savings
mise exec -- just kube encode-benchmark-results <savings-run-id>
```

Expected: full-file encodes only for cohorts with chosen settings, per-title validation and exact size measurements, median/IQR per cohort, and scratch outputs deleted after measurement.

- [ ] **Step 2: Execute the exact Plex contention protocol**

Record the designated physical client and NAS uplink speed. Run three 15-minute baseline plays with one seek every two minutes, then cases `a` through `d` with the guarded run recipe. Collect start latency, buffering count/duration, seek-to-resume, five-second NAS throughput, and encode wall time.

Pass only when cases `a`–`c` have zero buffering, start latency is within two seconds of baseline, and case `d` seek-to-resume never exceeds baseline by more than three seconds. A failure sets the recommended FileFlows processing-window width; it does not invalidate the benchmark.

- [ ] **Step 3: Generate run-scoped findings**

`benchmark.sh findings <run-id>` reads only manifests/results/review inputs for the named runs and writes `/out/runs/<run-id>/findings.md` containing:

- reconciled cohort counts and lifecycle totals;
- QSV setting and savings median/IQR per cohort;
- x265 matched-VMAF premium or unbracketed result;
- HDR validation and DV skip result;
- Plex contention table against the baseline thresholds;
- NAS uplink speed and measured throughput;
- addressable TiB and recoverable TiB, superseding the design estimate;
- GO/MARGINAL/NO-GO for every cohort and overall recommendation.

- [ ] **Step 4: Commit a sanitized dated findings decision as PR 4**

Create the dated decision with status `Proposed`, source design link, exact run IDs and image digest, quantitative tables, operator visual pass/fail, and explicit recommendation. Exclude movie paths, hashes, still images, Plex tokens/session payloads, and raw NAS telemetry. After operator accepts it, change status to `Accepted` in the same findings PR before merge authorization.

Run:

```bash
mise exec -- just repo links-validate
mise exec -- just ci
mise exec -- git add docs/decisions/YYYY-MM-DD-fileflows-movie-encoding-findings.md
mise exec -- git commit -m "docs(decisions): record movie encoding benchmark findings"
```

- [ ] **Step 5: Clean only explicitly approved run artifacts**

For each run the operator chooses to remove:

```bash
ENCODE_BENCHMARK_CLEAN_CONFIRM='delete:encode-benchmark:<run-id>' \
  mise exec -- just kube encode-benchmark-clean <run-id>
```

Expected: only `/out/runs/<run-id>` is deleted; other runs, census outputs, movie originals, Plex configuration, and media directories remain untouched. Report that run artifacts are unrecoverable unless separately backed up.

## Deferred Work

- FileFlows Server and two Flow Runners, Plex priority, and the processing window require a new implementation plan based on accepted findings.
- Audio pruning, Dolby Vision encoding, TV, and a dedicated ntfy producer identity remain unauthorized.
- The accepted preflight/placement mismatch remains documented; a scratch eviction is a failed run to re-dispatch, not a reason to pin nodes or alter the Intel GPU plugin.
