# FileFlows Movie Evaluation and Implementation Plan

## Objective

Evaluate and deploy FileFlows as the media normalization and optimization layer for the movie library.

The initial scope is intentionally narrow:

- Process **movies only**.
- Do **not** process TV shows.
- Preserve the existing Plex, Sonarr, Radarr, Prowlarr, qBittorrent, and qbit_manage workflows.
- Optimize only media where there is a measurable storage or compatibility benefit.
- Preserve source resolution, frame rate, HDR characteristics, high-quality audio, subtitles, and chapters.
- Introduce transcoding in controlled cohorts rather than enabling whole-library processing immediately.
- Keep Dolby Vision out of the initial transcoding scope.
- Require validation before any original file can be replaced.

TV shows are explicitly deferred to a later audit and must not be added to the FileFlows library during this implementation.

---

## 1. Current Environment

The media stack is managed through Talos Kubernetes and Flux GitOps.

Relevant existing components include:

- Plex
- Radarr
- Sonarr
- Prowlarr
- qBittorrent
- qbit_manage
- Gluetun
- SMB-backed media storage
- Longhorn-backed application storage

The media library uses this hierarchy:

```text
media/
├── movies/
└── tv/
```

For this project, FileFlows must be granted access only to:

```text
media/movies/
```

Do not configure `media/tv/` as a FileFlows library.

The three Talos nodes are Intel NUC11 systems using Intel Core i5-1135G7 processors with Intel Quick Sync-capable integrated graphics.

The desired architecture is:

```text
                       FileFlows Server
                              │
                          job queue
                              │
             ┌────────────────┼────────────────┐
             │                │                │
             ▼                ▼                ▼
          NUC 1            NUC 2            NUC 3
       Flow Runner       Flow Runner       Flow Runner
         Intel QSV         Intel QSV         Intel QSV
             │                │                │
             └────────────────┼────────────────┘
                              │
                              ▼
                       SMB movie library
```

Initially configure no more than **one simultaneous encoding job per NUC**.

Do not increase concurrency until storage, network, CPU, GPU, thermal, and Kubernetes behavior have been observed under three concurrent encodes.

---

## 2. Source Library Findings

The supplied MediaInfo manifest demonstrates multiple materially different media populations:

- 4K HEVC Main10 HDR10 UHD remuxes
- 4K HEVC Main10 Dolby Vision UHD remuxes
- 1080p AVC Blu-ray remuxes
- 1080p VC-1 Blu-ray material
- Smaller populations requiring later classification

The manifest analysis identified approximately:

| Cohort | Titles | Approximate size | Initial disposition |
|---|---:|---:|---|
| 4K HEVC Dolby Vision | 137 | 7.7 TiB | Skip |
| 4K HEVC HDR10 | 113 | 6.04 TiB | Phased candidates |
| 1080p AVC | 123 | 2.91 TiB | Strong candidates |
| 1080p VC-1 | 11 | Small pilot cohort | First pilot |

The library contains high-bitrate MakeMKV UHD sources, Dolby Vision Profile 7 sources using BL+EL+RPU with HDR10 compatibility, and conventional 1080p AVC Blu-ray remuxes around 20–36 Mb/s.

Dolby Vision Profile 7 must not be treated as ordinary HDR10 merely because it includes HDR10 fallback metadata.

---

## 3. FileFlows Suitability Evaluation

Before implementation, verify that the current stable FileFlows release satisfies these requirements:

- Container deployment
- Remote or distributed Flow Runners
- Intel Quick Sync
- HEVC encoding
- HEVC 10-bit encoding
- Codec detection
- Resolution detection
- Bitrate decisions
- Bit-depth detection
- Dolby Vision detection
- HDR10 detection
- Conditional flow branching
- Output-size comparison
- Duration validation
- Failure workflows
- Previously-processed detection
- Preservation or copying of non-video streams
- Deterministic Flow Runner identity
- Configurable work and temporary storage
- A stable, pinnable release

### Version selection

Evaluate the current FileFlows **Stable** release rather than automatically deploying `latest`.

1. Determine the current Stable FileFlows version.
2. Pin the container image by immutable version or digest.
3. Do not use an unpinned `latest` tag in Flux.
4. Record the selected version and release date in the implementation documentation.
5. Document whether any required feature is license-gated.

---

## 4. Safety Principles

These are hard requirements.

### Never reduce resolution

- A 4K source remains 4K.
- A 1080p source remains 1080p.
- Do not upscale or downscale.

### Do not blindly re-encode HEVC

HEVC is not itself a reason to transcode. A sufficiently efficient HEVC source must be skipped.

### Preserve HDR

HDR10 sources must remain:

- 10-bit
- BT.2020 where present
- PQ/ST 2084 where present
- HDR10 metadata-compatible

Any inability to demonstrate correct HDR preservation must block UHD processing.

### Skip Dolby Vision initially

Any detected Dolby Vision source must follow:

```text
Dolby Vision
     ↓
    SKIP
```

This includes Profile 7 UHD sources. Dolby Vision requires a separate later evaluation.

### Preserve primary lossless audio

Copy without re-encoding:

- Dolby TrueHD
- TrueHD Atmos
- DTS-HD Master Audio
- DTS:X

Do not convert these tracks to EAC3 or AC3 merely to save storage.

### Preserve secondary audio during initial rollout

Do not automatically remove:

- Commentary
- Alternate mixes
- Foreign-language audio
- AC3 compatibility tracks
- DTS cores

Audio cleanup is a separate future project.

### Preserve subtitles and chapters

Retain all existing subtitle streams, including PGS, and preserve chapter metadata.

### Preserve originals on every failure

A failed encode, validation error, hardware error, worker restart, or FileFlows crash must leave the source intact.

### Default to skip

Unknown classifications, incomplete metadata, missing hardware acceleration, or ambiguous validation results must produce `SKIP` or `FAIL`, never an automatic transcode.

---

## 5. GitOps Deployment Design

Create FileFlows under the existing media application hierarchy using established repository and app-template conventions.

Suggested structure:

```text
kubernetes/apps/media/fileflows/
├── app/
│   ├── helmrelease.yaml
│   ├── kustomization.yaml
│   └── ...
└── ks.yaml
```

Follow the repository's actual conventions if they differ.

### FileFlows Server

Deploy one FileFlows Server instance with:

- One replica
- Persistent application and database storage
- Internal service
- Internal Gateway/HTTPRoute or established ingress pattern
- Startup, readiness, and liveness probes
- Resource requests and limits
- Metrics where available
- Configuration persisted outside the container filesystem

Use Longhorn for FileFlows application state unless existing repository conventions indicate a better storage class.

### Movie storage

Mount the existing SMB media storage, but expose only:

```text
/media/movies
```

Do not define `/media/tv` as a FileFlows library. Where practical, do not mount the TV directory into FileFlows containers at all.

### Processing workspace

Do not use the Plex-visible movie library as temporary encoding workspace.

Evaluate:

- Node-local disk
- Dedicated persistent scratch storage
- Separate SMB scratch area

Prefer a design that minimizes:

- SMB read/write amplification
- Partially encoded files appearing in Plex
- Large temporary writes to Longhorn
- Loss of resumable work after a pod restart

Measure available node-local storage before selecting node-local scratch.

---

## 6. Intel Quick Sync Evaluation

Confirm that Talos exposes the Intel render device on all three NUCs:

```text
/dev/dri/
```

Verify the actual device nodes and permissions on every node. Do not assume the same render-device number without checking.

### Flow Runner topology

Evaluate:

- A DaemonSet with one Flow Runner per NUC
- Individually scheduled Deployments pinned to each NUC

Prefer a DaemonSet if FileFlows registration and deterministic worker identity work cleanly with it.

Each worker must retain a stable name across pod recreation, conceptually:

```text
fileflows-nuc1
fileflows-nuc2
fileflows-nuc3
```

### Hardware requirement

Production encode paths must explicitly require Intel QSV.

Do not silently fall back to CPU transcoding:

```text
Can use QSV?
     │
 ┌───┴───┐
 yes     no
  │       │
encode  fail/skip
```

Confirm QSV decode and HEVC encode behavior separately for AVC, VC-1, and HEVC Main10 inputs.

---

## 7. FileFlows Library Configuration

Create exactly one media-processing library:

```text
Movies
```

Path:

```text
/media/movies
```

Do not create a TV library.

Exclude:

- Hidden files
- Temporary files
- Partial downloads
- Recycle-bin directories
- Transcoding workspace
- Plex-generated files
- Filesystem metadata
- Active torrent payloads

Initially accept only intentionally supported media extensions, at minimum:

```text
.mkv
```

Evaluate MP4 and M4V separately if they exist in the library.

---

## 8. Main Movie Decision Flow

Create a reusable flow named approximately:

```text
Movie Media Optimization
```

Implement this structure:

```text
Video File
    │
    ▼
Currently seeded or active torrent?
    │
    ├── YES ───────────────────────────→ SKIP
    ▼
Already processed?
    │
    ├── YES ───────────────────────────→ SKIP
    ▼
Classify resolution
    │
    ├── 1080p ─────────────────────────→ 1080p policy
    ├── 4K ────────────────────────────→ 4K policy
    └── anything else ─────────────────→ SKIP + log
```

Use an explicit processed marker or equivalent metadata to prevent loops.

---

## 9. 1080p Decision Flow

The 1080p branch is the initial production proving ground.

```text
1080p
  │
  ▼
Codec
  │
  ├── VC-1 ────────────────────────────→ HEVC candidate
  │
  ├── AVC
  │     │
  │     ▼
  │   bitrate >= threshold?
  │     ├── yes ───────────────────────→ HEVC candidate
  │     └── no ────────────────────────→ SKIP
  │
  ├── HEVC ────────────────────────────→ SKIP
  └── other ───────────────────────────→ SKIP + log
```

### VC-1

All qualifying 1080p VC-1 movies are candidates because conversion provides:

- Modern codec normalization
- Potential storage reduction
- Improved long-term compatibility

Begin with only three pilot titles before processing the remaining cohort.

### AVC

Initially target clearly high-bitrate Blu-ray AVC remuxes:

```text
video bitrate >= 30 Mb/s
```

This is a conservative pilot threshold, not permanent policy.

---

## 10. 4K Decision Flow

Only activate this branch after the 1080p pilot succeeds.

```text
4K
 │
 ▼
Codec = HEVC?
 │
 ├── no ───────────────────────────────→ SKIP + audit
 └── yes
       │
       ▼
    Bit depth = 10?
       │
       ├── no ─────────────────────────→ SKIP
       └── yes
             │
             ▼
       Dolby Vision?
             │
         ┌───┴───┐
        yes      no
         │        │
        SKIP      ▼
               HDR10?
                 │
             ┌───┴───┐
            no       yes
             │         │
           SKIP     bitrate
                       │
             ┌─────────┴─────────┐
            <50                 >=50
             │                    │
            SKIP              candidate
```

Initial qualifying UHD criteria:

```text
resolution = 3840×2160 class
codec = HEVC
bit depth = 10
HDR = HDR10
Dolby Vision = false
video bitrate >= 50 Mb/s
```

Roll out the qualifying population in descending bitrate cohorts rather than enabling all `>=50 Mb/s` sources at once.

---

## 11. Encoding Strategy

Evaluate two strategies before production rollout.

### QSV quality-based encode

Use:

- Intel QSV
- HEVC
- 10-bit when the source is 10-bit
- Same resolution
- Same frame rate
- Quality-based rather than fixed-bitrate control

Do not use one fixed output bitrate for the entire library. Grain-heavy material may require substantially more bitrate than clean digital animation.

### FileFlows optimized encoding

Evaluate FileFlows' optimized encoding feature if licensing is acceptable.

Document:

- Required license tier
- Current cost
- Functional benefit
- Quality-sampling behavior
- Equivalent nonlicensed implementation

Do not make the deployment dependent on a paid feature without explicitly approving that dependency.

---

## 12. Benchmark Phase

Before whole-file production processing, choose representative source samples:

1. 1080p VC-1
2. High-bitrate 1080p AVC
3. Clean modern 4K HDR10
4. Grain-heavy 4K HDR10
5. Dark or high-motion 4K HDR10
6. Dolby Vision title for detection-only testing

Do not transcode the Dolby Vision sample.

For each eligible sample, compare:

- Original
- QSV conservative encode
- QSV balanced encode

Optionally compare a short CPU x265 encode as a quality and efficiency reference, but do not make CPU x265 the production path unless measurements justify it.

Record:

- Source and output size
- Source and output bitrate
- Encode FPS
- Elapsed duration
- CPU utilization
- Intel GPU utilization
- NUC temperature
- SMB throughput
- Codec
- Resolution
- Frame rate
- Bit depth
- HDR metadata
- Audio streams
- Subtitle streams
- Chapters
- Plex Direct Play behavior

Optionally calculate VMAF and SSIM where appropriate, but do not approve quality using a metric alone. Perform actual visual evaluation on representative playback hardware.

---

## 13. Output Validation Flow

No processed output may replace its source until validation succeeds.

```text
Encoded file
    │
    ▼
Decode/probe succeeds?
    ├── no ────────────────────────────→ FAIL
    ▼
Duration matches within tolerance?
    ├── no ────────────────────────────→ FAIL
    ▼
Resolution and frame rate match?
    ├── no ────────────────────────────→ FAIL
    ▼
Expected codec and bit depth?
    ├── no ────────────────────────────→ FAIL
    ▼
HDR metadata preserved where required?
    ├── no ────────────────────────────→ FAIL
    ▼
Audio streams retained?
    ├── no ────────────────────────────→ FAIL
    ▼
Subtitle streams retained?
    ├── no ────────────────────────────→ FAIL
    ▼
Chapters retained?
    ├── no ────────────────────────────→ FAIL
    ▼
Output meaningfully smaller?
    ├── no ────────────────────────────→ DISCARD OUTPUT
    └── yes ───────────────────────────→ ELIGIBLE FOR ACCEPTANCE
```

Where FileFlows lacks a native validation node, implement an auditable script or custom node rather than omitting the check.

---

## 14. Minimum Savings Gate

Start with a required reduction of:

```text
15%
```

The output must therefore be no larger than 85% of the source.

Examples:

| Original | Output | Reduction | Result |
|---:|---:|---:|---|
| 60 GiB | 48 GiB | 20% | Pass |
| 60 GiB | 56 GiB | 6.7% | Discard output |

The threshold may be adjusted only after reviewing real results.

---

## 15. Failure Handling

Create a FileFlows Failure Flow.

A processing error must:

1. Retain the original file.
2. Retain sufficient logs for debugging.
3. Identify the movie.
4. Identify the Flow Runner.
5. Identify the failed processing stage.
6. Remove or quarantine incomplete output.
7. Surface an alert through the homelab notification system when available.

Never retry an indefinitely failing encode. Use bounded retries only for transient conditions.

---

## 16. Phased Rollout

Do not enable whole-library processing. Each phase requires successful validation and review before progressing.

### Phase 0 — Deployment only

Deploy:

- FileFlows Server
- Three Flow Runners
- Storage mounts
- Intel QSV access
- Internal UI
- Persistent state

Keep processing disabled. Confirm all three workers register and survive pod and node recreation.

### Phase 1 — Dry-run classification

Add the movie library and run classification or audit logic without modifying files.

Confirm:

- TV is absent
- Active torrent detection works
- Codec classification works
- Resolution classification works
- HDR10 detection works
- Dolby Vision detection works
- Bitrate classification works
- Already-processed detection works

Generate counts per branch and compare them to the source manifest. Do not encode anything.

### Phase 2 — Small 1080p VC-1 pilot

Select three 1080p VC-1 movies.

Process them into HEVC and manually validate every output before allowing replacement. If successful, process the remaining VC-1 cohort.

### Phase 3 — High-bitrate 1080p AVC

Target:

```text
1080p AVC
video bitrate >= 30 Mb/s
```

Start with approximately five representative movies.

Validate:

- Visual quality
- Storage savings
- Plex Direct Play
- Audio preservation
- Subtitle preservation
- Chapter preservation

If successful, process the remaining qualifying AVC cohort. Do not yet process lower-bitrate AVC.

### Phase 4 — 4K HDR10 at or above 70 Mb/s

Target:

```text
4K
HEVC Main10
HDR10
not Dolby Vision
video bitrate >= 70 Mb/s
```

Start with three titles:

- Modern digital source
- Grain-heavy film source
- Dark or high-motion source

Confirm HDR preservation on real playback hardware before continuing.

### Phase 5 — 4K HDR10 from 60–70 Mb/s

After Phase 4 succeeds, enable the `60–70 Mb/s` cohort with all safeguards unchanged.

### Phase 6 — 4K HDR10 from 50–60 Mb/s

After Phase 5 succeeds, enable the `50–60 Mb/s` cohort.

### Phase 7 — Aggregate review

Pause expansion and analyze:

- Total TiB saved
- Mean and median reduction
- Encode duration
- Failure rate
- Average output bitrate
- Plex Direct Play rate
- Visual-quality findings
- Network and SMB load
- NUC thermals
- FileFlows stability

Then decide whether `40–50 Mb/s` UHD sources are worth processing. Do not automatically lower the threshold.

### Phase 8 — Dolby Vision evaluation

Dolby Vision remains excluded until this separate investigation covers:

- Profile 7
- BL+EL+RPU
- Profile 8 where present
- HDR10 fallback
- RPU preservation
- Enhancement-layer implications
- Plex compatibility
- Playback-device compatibility
- FileFlows and FFmpeg behavior
- Validation tooling

Do not enable Dolby Vision transcoding until preservation has been demonstrated end to end.

---

## 17. TV Boundary

TV is out of scope.

The implementation agent must not:

- Create a TV FileFlows library
- Mount TV write access where unnecessary
- Process Sonarr-managed TV files
- Derive TV policies from movie policies
- Assume TV media has the same bitrate, quality, or storage characteristics as movies

Create a backlog item:

```text
Audit TV media library and design a separate FileFlows policy
```

That future work must begin with a separate MediaInfo manifest of `media/tv/`.

---

## 18. Plex and Arr Boundaries

FileFlows must not become part of acquisition.

```text
Prowlarr
   ↓
Radarr
   ↓
qBittorrent
   ↓
Radarr import
   ↓
media/movies
   ↓
FileFlows
   ↓
Plex
```

FileFlows acts only after media exists in the movie library.

It must not:

- Initiate downloads
- Interact with indexers
- Replace Radarr import logic
- Replace qbit_manage
- Decide torrent seeding policy

---

## 19. Radarr Considerations

Evaluate how FileFlows replacement of a Radarr-managed file affects:

- Radarr file size
- Radarr codec metadata
- MediaInfo shown in Radarr
- Rescan behavior
- Upgrade eligibility
- File modification detection
- Custom-format scoring, if applicable

Determine whether FileFlows should trigger a targeted Radarr rescan through its API or whether scheduled refresh behavior is sufficient.

Do not enable destructive replacement until Radarr behavior is verified.

---

## 20. Plex Considerations

After successful replacement:

- Plex must detect the replacement.
- Plex must update media metadata.
- Playback should remain Direct Play where supported.
- HDR identification must remain correct.

Determine whether Plex automatic library detection is sufficient or whether FileFlows should trigger a targeted scan.

Do not trigger a full Plex library scan after every movie unless necessary.

---

## 21. Seeding Boundary

Do not optimize files that are participating in an active qBittorrent torrent.

Changing even one byte causes the media file to fail the torrent's original hashes.

```text
active torrent or seeding
          ↓
         SKIP
```

Personally ripped disc media that is not tied to an existing torrent is eligible for the normal FileFlows policy.

The implementation must define how it identifies active torrent payloads. It must fail closed if qBittorrent state cannot be confirmed.

Any future workflow for creating a distributable derived encode remains separate from qbit_manage's management of existing torrents.

---

## 22. Observability

Capture at minimum:

### FileFlows Server

- Queue depth
- Jobs completed
- Failed jobs
- Average processing duration

### Per worker

- Active jobs
- CPU
- RAM
- Intel GPU load, if exposed
- Temperature
- Disk and temporary-space usage

### Storage

- SMB read throughput
- SMB write throughput
- Latency where available

### Per completed encode

Record:

```text
movie
source codec
source resolution
source bitrate
source size
output codec
output bitrate
output size
percentage saved
processing node
processing duration
validation result
final disposition
```

---

## 23. Success Criteria

The implementation is successful when:

1. FileFlows is fully deployed through Flux.
2. Server state survives pod replacement.
3. One deterministic worker runs on each NUC.
4. Intel QSV is verified on all three workers.
5. TV is not visible to the processing library.
6. Dry-run classification correctly identifies major movie populations.
7. Active torrent payloads are reliably excluded.
8. Dolby Vision is reliably excluded.
9. The 1080p VC-1 pilot succeeds.
10. High-bitrate AVC processing succeeds.
11. HDR10 UHD processing preserves 4K, frame rate, 10-bit, and HDR metadata.
12. Primary lossless audio remains unchanged.
13. Subtitles and chapters survive.
14. Failed jobs never destroy originals.
15. Outputs below the savings threshold are rejected.
16. Plex successfully plays accepted outputs.
17. Radarr remains consistent with modified files.
18. Deployment and policy configuration are documented.

---

## 24. Deliverables

### GitOps

- FileFlows namespace and app definition following repository conventions
- Pinned FileFlows version
- Server deployment
- Persistent storage
- Service
- Gateway/HTTPRoute or existing ingress equivalent
- Flow Runner workloads
- `/dev/dri` access
- SMB movie mount
- Configuration and secrets
- Probes
- Resource constraints
- Flux dependencies
- Processing-disabled rollout control

### FileFlows configuration

Document or manage declaratively where practical:

- Movies library
- Processing flow
- Validation flow
- Failure flow
- Worker configuration
- Concurrency
- Exclusions
- Active torrent gate
- Processed markers

If FileFlows flow configuration cannot be cleanly managed as code, document the exact manual configuration in the media startup guide and export configuration backups where supported.

### Documentation

Update the media-stack documentation with:

- Architecture
- Deployment
- UI location
- Worker topology
- Movie-only scope
- Processing rules
- Current rollout phase
- Rollback procedure
- Excluded Dolby Vision policy
- Active torrent exclusion
- Deferred TV audit

---

## 25. Verification

The implementation agent must verify the deployment rather than stopping at manifest generation.

Test:

```text
Server healthy
Workers registered
QSV available
SMB movie path readable
Movie path writable when required
TV unavailable
Dry-run classification
Active torrent exclusion
Processed marker behavior
Failure path
VC-1 test encode
AVC test encode
HDR10 test encode
Output validation
Minimum-savings rejection
Plex playback
Radarr rescan behavior
Server pod recreation
Worker pod recreation
Node recreation or rescheduling
```

Record verification evidence in the implementation PR.

---

## 26. Rollback

At every phase, rollback must mean:

```text
disable processing
```

without requiring removal of FileFlows.

Provide a simple Flux-controlled mechanism to stop new jobs while keeping the UI, configuration, and history available.

Never require restoring the entire movie library from backup as a normal rollback mechanism.

During pilot phases, retain originals until each transformed output has been reviewed and explicitly accepted.

---

## 27. Initial Production Policy

At project completion, the initial policy should be no broader than:

```text
1080p VC-1
    → HEVC candidate

1080p AVC >=30 Mb/s
    → HEVC candidate

4K HEVC Main10 HDR10 >=50 Mb/s
    → HEVC 10-bit candidate, phased by bitrate

4K Dolby Vision
    → SKIP

4K HEVC HDR10 <50 Mb/s
    → SKIP

Existing efficient HEVC
    → SKIP

Active torrent payload
    → SKIP

Unknown classification
    → SKIP
```

The default for uncertainty is always `SKIP`, never `TRANSCODE`.

---

## 28. Required Implementation Order

The implementation agent should execute the work in this sequence:

1. Inspect repository conventions.
2. Verify the current FileFlows Stable release.
3. Confirm feature licensing requirements.
4. Verify Talos `/dev/dri` availability.
5. Measure available processing workspace.
6. Design the FileFlows Server.
7. Design Flow Runner topology.
8. Design the active torrent exclusion gate.
9. Implement GitOps resources.
10. Deploy with processing disabled.
11. Verify persistence, network, storage, and QSV.
12. Create the movie-only FileFlows library.
13. Implement a classification-only flow.
14. Compare classification against the manifest.
15. Implement validation and failure flows.
16. Benchmark representative files.
17. Select QSV quality settings.
18. Process three VC-1 pilots.
19. Review and complete the remaining VC-1 cohort.
20. Process five high-bitrate AVC pilots.
21. Review and complete the qualifying AVC cohort.
22. Process three HDR10 titles at or above 70 Mb/s.
23. Review HDR playback and metadata.
24. Complete the remaining `>=70 Mb/s` cohort.
25. Continue with `60–70 Mb/s`.
26. Continue with `50–60 Mb/s`.
27. Stop and review aggregate results.
28. Decide whether `40–50 Mb/s` is justified.
29. Document the deferred Dolby Vision evaluation.
30. Document the deferred TV audit.

Do not collapse these phases merely because earlier tests pass.

The objective is not to transcode the library as quickly as possible. The objective is to establish a safe, repeatable optimization system that can operate continuously across the movie library without degrading high-value media.
