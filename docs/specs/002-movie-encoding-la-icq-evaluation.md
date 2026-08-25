# Movie Encoding LA-ICQ Evaluation

## Purpose and outcome

This design tested whether Intel Quick Sync Video (QSV) HEVC with look-ahead
intelligent constant quality (LA-ICQ) could preserve difficult movie material and
recover enough storage to justify a FileFlows platform.

The chosen approach was a standalone, disposable Kubernetes benchmark. It answered the
quality-and-savings question before the repository deployed FileFlows, changed the Intel
GPU plugin, or gave an encoding workload write access to the movie library. The
benchmark's deliverable was a decision, not a reusable media dataset.

**Historical outcome: NO-GO for the LA-ICQ strategy.** Both eligible nodes initialized
QSV and showed fixed-function video activity, positive progress, successful decode, and
VMAF availability, but both selected `ICQ` rather than the required `LA-ICQ`. Exact
rate-control selection was a load-bearing eligibility predicate, so no corrected quality
or savings run was justified. This result prevented an unsupported FileFlows deployment;
it did not select another encoder.

The current encode-benchmark source has since evolved to implement the distinct
`qsv-hevc-icq-v1` strategy. Its wider quality range and `-look_ahead 0 -extbrc 0`
command are current facts for that later evaluation, not corrections to this historical
LA-ICQ design. Current source, current application documentation, and current operator
workflows remain authoritative for using the retained harness.

## Problem and decision context

The initial FileFlows proposal was deploy-first: build a server, three GPU runners,
storage, probes, and classification flows before encoding a frame. That sequence deferred
the question most likely to invalidate the project: whether QSV HEVC could retain
acceptable quality, especially on grain-heavy 4K HDR10 material, while reducing size
enough to repay the operational cost.

This design inverted the sequence. A small Git-managed experiment would first prove the
exact hardware path, reject weak settings with difficult clips, estimate savings with
representative full titles, and measure Plex contention. FileFlows would be designed only
after those measurements established useful scope.

Three system constraints shaped that choice.

### Torrent and hardlink economics

Radarr imported downloads into the movie library with hardlinks. Re-encoding creates new
bytes and breaks that sharing relationship. Whether it saves space depends on torrent
lifecycle, not on the source codec alone:

| Lifecycle state | Storage consequence | Experiment treatment |
| --- | --- | --- |
| Active or seeding | A changed payload breaks torrent hashes | Skip |
| Private-permanent | The download copy remains indefinitely, so an encode adds storage | Exclude from savings claims |
| Public-awaiting-cleanup | Savings appear only after download cleanup and its recycle interval | Report delayed realization |
| Unlinked | The original has one library link; savings are immediate | Eligible |

Classification used two evidence stages. A link count of one proved the combined
`unlinked` state. A linked entry required a credential-redacted torrent inventory:
current torrent state distinguished active work, and tracker tags distinguished stopped
private-permanent work from public work awaiting cleanup. A linked entry with no matching
torrent evidence failed closed as `active`. Muxing metadata such as a MakeMKV tag could
describe how a file was created but could not prove that the present file was a torrent
payload. Once a cleaned file and its torrent history were gone, the census could not
distinguish it from a never-torrented file; both were deliberately classified as
`unlinked` because their storage consequence was identical.

The completed census later showed that this risk was small in the measured library: 393
of 397 titles were unlinked, four were active, and none were private-permanent or
public-awaiting-cleanup. That corrected the concern without weakening the lifecycle
model.

### GPU topology and Plex precedence

The three-node cluster advertised one i915 resource per node because the Intel GPU plugin
did not expose shared device slots. Plex continuously requested one of those resources.
A three-runner FileFlows topology therefore had no safe place for Plex to reschedule: one
runner would stay pending or Plex would have to share a physical GPU.

The credible production shape, if the experiment passed, was two runners with required
anti-affinity from Plex. That spent two GPU slots and reserved one for Plex without
changing the plugin. The modeled full-catalog cost was about one additional day compared
with three runners, a small one-time cost for structural isolation.

The benchmark used the same isolation rule. Each GPU Job requested exactly one i915
resource and could not share Plex's node. A negative PriorityClass, now also expressed by
the retained source as non-preempting, prevented the benchmark from displacing ordinary
workloads and allowed higher-priority production work to take precedence. This was a
scheduler property, not a claim about kubelet eviction order.

### Storage and network contention

Node-local scratch was preferable to the SMB share because intermediate encodes could be
large and did not need durable retention. The source remained on SMB and was read
directly; scratch held one encode output at a time, not a source copy. The output share
held only run metadata, measurements, stills, logs, and explicitly selected full-title
finalists.

GPU isolation did not eliminate NAS contention. The original model estimated that two
fast 1080p encodes plus Plex could approach 100 MB/s of aggregate reads, and that a
finished full-title encode could create a short write-back spike. These were sizing
estimates, not evidence. The design therefore included a reproducible Plex contention
protocol rather than treating modeled bandwidth as a guarantee.

## Alternatives considered

| Approach | Decision and rationale |
| --- | --- |
| Deploy all of FileFlows, then benchmark | Rejected. It built the full platform before answering the question most likely to kill it. |
| Deploy a FileFlows server and one runner for the benchmark | Rejected. It still required much of the application and storage work before producing evidence. |
| Standalone, operator-dispatched benchmark Jobs | Chosen. It isolated the decisive question, fit GitOps review, and could be discarded without a production migration. |
| Put an ad hoc script on the SMB share and run a generic image | Rejected. The fastest iteration path placed executable behavior outside Git review and history. |
| Build and publish a custom benchmark image | Rejected for the initial experiment. A pinned public FFmpeg image plus versioned ConfigMap scripts avoided a registry and release loop for temporary tooling. A split encode/analysis image was the fallback if one image could not supply QSV, VMAF, x265, and shell utilities. |
| Raise the GPU plugin's shared-device count | Rejected. The advertised slots would still map the same physical render device and would provide no hardware partition or contention guarantee. |
| Pin every expensive Job to the node checked by preflight | Rejected. It added dispatch machinery and could deadlock against Plex's GPU placement. The bounded placement gap was accepted instead. |
| Require every eligible node to pass free-space preflight | Rejected. One low-space node would block a run that could safely use another node. |

Software x265 remained only a matched-quality yardstick. It was too slow to assume as the
production engine, and this design did not authorize it as one.

## Experiment architecture

Flux reconciled only inert inputs: the versioned scripts, sample manifest, and background
PriorityClass. The Job template remained outside the application's rendered
Kustomization. Reconciliation could not create an encoder Job; an operator had to use a
guarded dispatcher for a selected mode.

The benchmark had three storage boundaries:

| Mount | Source boundary | Access | Purpose |
| --- | --- | --- | --- |
| `/media` | Movie-library subdirectory only | Read-only | Source titles |
| `/out` | Benchmark subdirectory outside the media library | Read-write | Run-scoped durable evidence |
| `/scratch` | Node-local `emptyDir` | Read-write | Temporary clips and encodes |

The Jobs could not see TV or downloads. Benchmark output lived outside the media-library
paths that Plex and Radarr indexed or managed. This made source-library protection
independent of script correctness.

Every container ran as the media UID and GID, as non-root, with privilege escalation
disabled, all Linux capabilities dropped, a runtime-default seccomp profile, and no
service-account token. Jobs used `restartPolicy: Never`, `backoffLimit: 0`, and a finite
deadline. Failure therefore left the original intact and could not silently create a
second attempt.

The design distinguished structural guarantees from bounded operational mitigations.
The read-only movie mount, absence of TV and downloads, output outside library paths,
non-root sandbox, dropped capabilities, no automatic retry, and finite deadline remained
enforced even if harness logic was wrong. Free-space preflight, storage requests and
limits, node-placement assumptions, and negative scheduler priority instead reduced the
chance and consequence of node pressure: they did not guarantee free space on the node
that ultimately ran the Job, and scheduler priority did not guarantee kubelet eviction
order.

Offline tests existed because the harness made safety-sensitive classification,
mutation, and evidence decisions around the media library. They encoded the load-bearing
contracts for classification, run and resume identity, rendered storage boundaries,
confirmation guards, and result schemas rather than leaving those contracts as
conventions. The mount-boundary and mutation-confirmation checks were especially
important because they made source-library protection enforceable in CI. Current source
and tests remain authoritative for the retained harness.

The runtime image had to be pinned by digest and empirically provide a real QSV encode,
the required VMAF path, libx265, FFprobe, the shell utilities used by the scripts, and
non-root execution. The implementation selected a LinuxServer FFmpeg image after this
proof. A codec advertised by `ffmpeg -encoders` alone was not sufficient evidence.

### Storage-contract correction

The first resource figures were impossible. The original preflight required more free
space than the nodes' ephemeral partition contained, and the Job requested more
ephemeral storage than Kubernetes reported as allocatable. The completed census and
measured node limits corrected the contract:

| Control | Corrected value |
| --- | ---: |
| `emptyDir.sizeLimit` | 105 GiB |
| `ephemeral-storage` request | 105 GiB |
| `ephemeral-storage` limit | 110 GiB |
| Preflight free-space floor | 115 GiB |

The largest measured title was 88.18 GiB. Since scratch held one output, 105 GiB supplied
about 19 percent headroom and remained below the 134.66 GiB node-allocatable value. The
110 GiB limit bounded unexpected growth. These values assumed a quality-targeted encode
would not exceed about 1.19 times its source; if that assumption failed, the Job would be
evicted after wasting one encode rather than modifying media.

Preflight measured actual free space but did not bind the Job to the measured node.
Kubernetes schedules ephemeral-storage requests against allocatable capacity and
requests, not current free bytes. This placement gap was accepted because its consequence
was bounded by the read-only source, run-scoped output, `emptyDir.sizeLimit`, and no-retry
policy. It was a mitigation with a known failure mode, not a safety guarantee.

## Experiment populations and methodology

The harness separated samples used to reject poor quality from samples used to estimate
catalog savings. Combining them would bias the estimate: deliberately difficult material
is a good rejection instrument and a bad representation of the catalog.

### Measurement limitations and failure hypotheses

The experiment treated three codec and measurement limitations as design inputs. QSV
could lose HDR10 static metadata, so quality validation compared outputs with the
title-level metadata oracle rather than assuming that a copied clip retained every SEI
message. HEVC provides no film-grain synthesis, so grain-heavy stress roles were
necessary and a grain-caused quality or savings no-go was a legitimate result. VMAF was
trained for SDR and was weak evidence for HDR approval; each clip's scores could reject a
setting, but only mandatory visual judgment could approve a candidate.

### Stage 0: metadata census

A CPU-only Job walked only the movie mount and used metadata-level FFprobe calls. It did
not count packets or read every media byte merely to estimate the catalog. It recorded
cohort, source properties, hardlink state, and audio inventory. Audio sizes were marked
as reported, estimated from bitrate and duration, or unknown; exact per-track byte counts
were deferred to full reads because some lossless tracks do not report bitrate.

The census established the sampling frame and reconciled the initial capacity estimate.
It was reconnaissance, not evidence that any encoder was acceptable.

### Stage 1: two pinned panels

The quality panel contained seven roles selected to stress failure modes:

1. one 1080p VC-1 title;
2. one clean, high-bitrate 1080p AVC title;
3. one grain-heavy, high-bitrate 1080p AVC title;
4. one clean 4K HDR10 title;
5. one grain-heavy 4K HDR10 title, the decisive grain-smoothing case;
6. one dark or high-motion 4K HDR10 title; and
7. one Dolby Vision Profile 7 title used only to prove detection and exclusion.

The Dolby Vision title was never encoded, so six titles contributed quality rows.
The savings panel was a seeded, stratified draw of approximately 24 full titles, about
eight per major eligible cohort and spread across bitrate bands. The seed and selected
sources were immutable experiment inputs. This panel estimated the catalog; it did not
reuse the biased stress sample.

### Stage 2: stable clips

Each encodable quality title supplied three pinned approximately 90-second regions named
`detail`, `dark`, and `motion`. The harness extracted them by stream copy so it did not
measure an encode of an encode. Keyframe alignment could move a boundary slightly, but
the pinned title and timestamp made every rerun select the same intended scene. The
harness never substituted another title or timestamp at runtime.

### Stage 3: encoder sweeps

The LA-ICQ QSV sweep combined requested `-global_quality` values 20, 22, 24, 26, and 28
with look-ahead and extended bitrate control. Six titles, three clips, and five settings
defined 90 expected QSV clip encodes. The runtime-selected rate-control mode, parsed from
verbose encoder initialization, determined eligibility; requested flags could not prove
that LA-ICQ was actually active.

Software x265 used `preset slow` and began at CRF 18, 20, 22, and 24 for only the
grain-heavy AVC and HDR10 references. Its curve extended in steps when necessary to
bracket the QSV VMAF point. Comparison permitted interpolation inside a measured bracket
and prohibited extrapolation. An unbracketed point produced no verdict.

Only after the quality panel selected a setting could the savings panel encode complete
titles at that cohort's setting. Each output was measured and discarded from scratch.
Only separately selected finalists could be copied to durable `encodes/` storage.

### Stage 4: Plex contention

The same designated physical playback client and fixed UHD HDR10 source were used for all
runs. Three 15-minute baselines used the same seek sequence as the contention seek case.
The cases were:

- direct play with one 4K encode;
- direct play with two concurrent 1080p encodes;
- forced transcode with two concurrent 1080p encodes; and
- the two-1080p direct-play case with one seek every two minutes.

Each run recorded playback-start latency, buffering count and duration, seek-to-resume
latency, NAS throughput at five-second intervals, and encode wall time. Cases without
seeks required zero buffering and a start latency within two seconds of baseline. The
seek case allowed no seek-to-resume result more than three seconds worse than baseline.
A failure would have sized a future FileFlows processing window; it would not have
changed a media file.

### Stage 5: visual review

Objective metrics screened candidates but did not replace human review. Matched-timestamp
source and output crops exposed grain smoothing quickly. Full-title finalists could be
placed in a temporary Plex library to check motion, Direct Play, and HDR behavior on the
real client. This UI-level library change was approved as reversible and separate from a
Plex deployment change; it could leave bounded thumbnail or metadata residue on Plex's
configuration volume. No Plex manifest change was authorized.

## Run identity, evidence, and resume

Durable evidence was scoped to `/out/runs/<run-id>/`. The immutable manifest was written
before measured work and the tree then held results, logs, stills, and selected finalist
encodes. Failed attempts stayed visible; only an exact complete row could be skipped on
resume.

The manifest bound all inputs capable of changing a result:

- the configured, dispatched, and running image digest;
- hashes of scripts and the sample manifest;
- strategy, schema, mode, selected settings, and full encoder command identities;
- source identities, sizes, and hashes;
- node, kernel, GPU driver, runtime, FFmpeg, and applicable CPU/x265 identities;
- the VMAF model and version; and
- the savings seed, playback-client label, and upstream evidence where applicable.

A new invocation created a UTC timestamp plus an identity-hash suffix. Resume was always
operator-directed with an explicit run ID. It required exact normalized identity equality
and preserved the original manifest bytes. A changed source, script, command, image,
model, node/runtime identity, selected setting, or upstream evidence aborted with a
redacted field-level difference. It did not discover a similar run, merge rows across
runs, or silently start a replacement.

## Capability and evidence contract

The capability proof ran the same production QSV command path as measured variants. A
node passed only when all of these independent predicates held:

- QSV hardware-device initialization succeeded;
- verbose encoder evidence selected exactly `LA-ICQ`;
- FFmpeg held the configured i915 render-node descriptor;
- DRM fdinfo reported a positive video-engine busy-time delta;
- encode progress was finite and positive;
- the primary output video decoded; and
- the configured VMAF comparison completed.

The five-second synthetic proof treated finite positive progress as a capability
predicate; its speed could not establish a production throughput band because fixed
initialization cost and synthetic content dominated it. Before dispatching the corrected
real-content sweep, measured per-variant runtimes had to support a credible worst-case
range and confirm that the finite Job deadline remained sufficient.

The telemetry sampler followed FFmpeg's render-node descriptor into
`/proc/<pid>/fdinfo`, required the i915 driver and nanosecond `drm-engine-*` counters,
and treated temporary counter regression by retaining the largest observed value until a
later sample exceeded it. It did not sum unrelated processes or descriptors.

Missing or malformed telemetry, wrong units, an unavailable render-node descriptor, or
another unavailable oracle produced `harness-blocked`. Such evidence described a
measurement defect and could not prove the platform ineligible. Once all oracles were
valid, absence of LA-ICQ or video-engine activity was a semantic capability failure.

Capability dispatch targeted each eligible non-Plex node and retained per-node evidence.
The platform could be declared ineligible only if every eligible node produced a complete
semantic failure under valid oracles. A passing node preserved eligibility; a
`harness-blocked` node prevented a cluster-wide verdict. Every expensive Job repeated
the short proof on its assigned node before source hashing or run-directory creation.
This closed the gap between committed evidence from one node and scheduler placement on
another.

## Quality-run correction and invalidation

The first quality attempt stopped after 44 variants. Forty rows were invalid and four
were marked passed; 25 QSV rows selected ICQ, every QSV proof was suspect, and GPU busy
evidence was empty. It also exposed several independent harness defects:

- child FFmpeg processes inherited the panel loop's standard input and consumed later
  clip or title records;
- decode validation mapped all streams and could fail while trying to select an encoder
  for a PGS subtitle, even though the primary video decoded;
- a copied HDR clip could omit static metadata present in the original title, producing
  a false mismatch;
- x265 ran outside its two grain-reference samples; and
- measured x265 runtime disproved the original two-to-three-hour quality-run estimate.

The corrected contract added `-nostdin` to every FFmpeg invocation in quality, savings,
finalist, contention, and still-generation paths. Decode validation mapped only the
primary video; separate probes continued to check audio, subtitle, and chapter counts.
HDR expectations came from the full source title while the clip remained the duration and
stream-layout reference. Explicit sample metadata restricted x265 to one grain-heavy AVC
and one grain-heavy HDR10 title. The capability-first gate moved expensive work behind
per-node proof.

These fixes did not lower quality thresholds, discard low-scoring frames, substitute ICQ
for LA-ICQ, or make the stopped run admissible. Changing scripts or capability semantics
changed run identity. The earlier rows could never be repaired or resumed into a valid
candidate population.

## Decision gates

A setting qualified for a cohort only if every applicable clip independently met every
gate. Pooling frames across clips was forbidden because a strong scene could otherwise
hide the exact weak scene the stress panel was selected to detect.

| Quality criterion | Required result |
| --- | --- |
| VMAF harmonic mean | At least 95 |
| VMAF one-percent low | At least 90 |
| Decode and output validation | No failure |
| Selected rate control | Exactly `LA-ICQ` |
| Operator visual assessment | Pass for the candidate |

Output validation covered duration tolerance, codec, resolution, frame rate, bit depth,
HDR mode and static metadata, and audio, subtitle, and chapter counts. A failing row was
retained as evidence rather than terminating the whole sweep. The qualified setting with
the greatest measured reduction would have become the cohort setting.

Savings used complete titles and was reported per cohort as median and interquartile
range:

| Median reduction | Historical verdict |
| --- | --- |
| At least 25 percent | Go |
| 15 to 25 percent | Marginal; operator decision with encode-time cost |
| Less than 15 percent | No-go |

The x265 comparison used its measured rate-quality curve at matched VMAF. A QSV bitrate
premium of at most 15 percent favored QSV; 15 to 30 percent was acceptable with a stated
cost; more than 30 percent meant QSV was materially worse. A curve that did not bracket
the QSV point yielded no comparison verdict.

The intended per-file production policy was quality-targeted encoding followed by a
measured savings gate. Static source-bitrate thresholds could remain scheduling hints,
but could not substitute for measuring whether a particular output actually shrank.

## Validated result

The retained census supplied useful, publish-safe reconnaissance:

| Aggregate | Verified value |
| --- | ---: |
| Titles | 397 |
| Total size | 17.26 TiB |
| AVC | 125 titles; 2.92 TiB |
| Dolby Vision | 126 titles; 7.63 TiB |
| HDR10 | 128 titles; 6.28 TiB |
| VC-1 | 11 titles; 0.20 TiB |
| Other or unspecified | 7 titles; 0.21 TiB |
| Unlinked | 393 titles |
| Active | 4 titles |
| Private-permanent or public-awaiting-cleanup | 0 titles |
| Probe failures | 1 title |

The corrected per-node capability proof then produced a decisive result. Both eligible
nodes showed valid telemetry and execution, but both selected ICQ. Because the platform
failed the exact LA-ICQ predicate under valid oracles, the quality sweep did not restart.

The invalid first run produced no admissible cohort setting, savings distribution, x265
matched-quality comparison, visual finalist verdict, or Plex contention result. The
census figures did not recommend an encoder, authorize FileFlows, or authorize replacing
any movie.

## Reconsideration and deferred scope

The no-go arose from an objective strategy predicate rather than an unresolved visual
judgment. Reconsidering this same LA-ICQ strategy requires a materially different driver,
runtime, or hardware condition that can plausibly select LA-ICQ, followed by a new run
identity and every applicable corrected stage: per-node LA-ICQ capability proof;
per-clip quality and output validation; mandatory visual approval; a bracketed x265
matched-quality comparison, with no verdict when its curve does not bracket the QSV
point; representative full-title savings; and Plex contention measurement. The stopped
run supplies none of this evidence and remains permanently inadmissible.

ICQ without look-ahead, AV1, software x265 as a production engine, another runtime, or
new hardware is a distinct strategy and needs its own design lineage. A later ICQ result
cannot retroactively satisfy this LA-ICQ requirement or change its no-go.

This design intentionally did not authorize:

- a FileFlows deployment or runner topology;
- any media replacement or Radarr/Plex library migration;
- Dolby Vision encoding;
- TV-library evaluation;
- audio pruning, subtitle cleanup, or metadata hygiene;
- an Intel GPU plugin change;
- a Plex deployment or priority change; or
- a different encoder strategy.

The benchmark succeeded in its primary purpose: it resolved the decisive technical
predicate before a multi-node encoding platform or destructive media workflow existed.
