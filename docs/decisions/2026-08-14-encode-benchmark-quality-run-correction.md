# Encode benchmark quality-run correction — amendment

- **Status: Accepted.**
Amends [Movie encoding benchmark — design](2026-08-01-fileflows-movie-encoding.md).
Date: 2026-08-14.
Branch: `fileflows-movie-encoding-strategy`.

This draft is additive. It preserves the accepted LA-ICQ eligibility gate and
adds a capability-first correction boundary after the first quality run exposed
runtime and harness defects.

## Context

Quality run `20260813T221312Z-5a22cde6` was stopped after a live audit. It
recorded 44 variants: 40 invalid and 4 passed. The run cannot support a cohort
decision.

The audit established these facts:

- All 25 QSV rows reported `ICQ`, not required `LA-ICQ`, and every QSV proof
  was `suspect`.
- GPU busy evidence files were empty.
- Only the `detail` clip ran for each reached title. Foreground FFmpeg commands
  inherited the clip loop's standard input and could consume the remaining
  `dark` and `motion` records.
- Full-stream decode validation failed when `-map 0 -f null -` attempted to
  select an encoder for mapped PGS subtitle streams.
- HDR reference clips sometimes probed without static mastering metadata while
  encoded outputs contained the title's metadata, producing a false mismatch.
- The implementation ran x265 on every encodable sample. The accepted decision
  limits x265 to the grain-heavy AVC and grain-heavy HDR10 samples.
- The measured x265 runtime, especially on Goodfellas, disproved the plan's
  2–3 hour total estimate.

The operator chose to preserve the accepted LA-ICQ eligibility gate. A verified
platform inability to provide LA-ICQ makes QSV ineligible; it does not authorize
silently evaluating ICQ instead.

## Goals

1. Fail before an expensive benchmark unless the exact production QSV path
   proves LA-ICQ, hardware activity, and forward encode progress.
2. Distinguish a platform limitation from harness defects.
3. Correct the live defects without weakening the accepted decision gates.
4. Reproduce every corrected defect with an independent regression test.
5. Start a fresh run only after committed evidence, merged corrections, Flux
   reconciliation, and preflight.

## Non-goals

- Do not amend the accepted LA-ICQ requirement.
- Do not revise accepted decision records. Later findings may supersede runtime
  estimates with measured evidence.
- Do not smooth, discard, or redefine low VMAF frames.
- Do not reuse or resume the failed run after scripts change.
- Do not delete the failed run artifacts until corrected-run evidence and tests
  are accepted.

## 1. Strong capability contract

The existing capability probe uses the production QSV flags but only checks
that an encode succeeds. It will use the same `run_qsv_encode` and `qsv_proof`
path as measured variants.

A capability result passes only when all conditions hold:

- hardware-device initialization passes;
- verbose encoder evidence selects exactly `LA-ICQ`;
- GPU engine telemetry is present and increases during the encode;
- encode speed is finite and positive, which proves forward progress;
- output video decodes; and
- the existing VMAF availability check passes.

The compact, path-free JSON result records selected rate control, initialization,
GPU busy percentage, encode speed, proof status, and proof reasons. A failed
proof exits nonzero after emitting sanitized evidence.

The five-second synthetic capability encode reports speed for diagnostics but
does not apply a production throughput band. Fixed initialization cost and
synthetic content make its speed incomparable with sustained real-content
throughput. Measured variants on the selected source clips retain the hard
speed bounds that determine whether a setting is operationally useful.

Telemetry availability is a harness precondition, not a platform verdict. The
sampler reads FFmpeg's DRM render-node descriptor from
`/proc/<ffmpeg-pid>/fdinfo/<fd>`. It requires `drm-driver: i915` and samples the
standard `drm-engine-<name>: <uint> ns` client busy-time counters. It identifies
the descriptor by resolving `/proc/<ffmpeg-pid>/fd/<fd>` to the configured DRM
render node; it does not sum unrelated descriptors or processes. The sampler
uses the counter's declared nanosecond unit and monotonic wall-clock
nanoseconds. It reports each engine separately and requires a positive video
engine delta to prove fixed-function encode activity. When a matching
`drm-engine-capacity-<name>` field exists, utilization divides by that positive
capacity; otherwise it uses the standardized default capacity of one.

The Linux DRM usage-statistics contract permits a counter to fall temporarily
but requires it to catch up. The sampler therefore retains the largest observed
value for each engine and accepts activity only after a later sample exceeds
the retained baseline. Missing descriptors, a driver mismatch, absent video
engine counters, unreadable or malformed fields, a unit other than `ns`, or an
invalid capacity produces `harness-blocked` evidence and cannot classify QSV as
ineligible. Once this telemetry oracle is available, no positive video-engine
delta makes the capability proof fail. The interface and units come from the
[Linux DRM client usage statistics specification][drm-usage-stats]; the targeted
capability Job validates that the running node and container expose them before
it makes a hardware-activity claim.

The previously committed capability evidence proved a weaker contract. The
first correction changes it from `verified` to `pending`. Quality, savings,
finalist, and contention dispatch refuse before Job creation unless committed
evidence proves the stronger contract. Capability dispatch remains exempt so it
can produce that evidence. A status string alone is insufficient: the committed
schema carries the measured initialization, selected rate control, telemetry,
speed, decode, and VMAF fields, and dispatch re-evaluates those fields against
the same versioned capability predicate. Missing, stale, contradictory, or
non-positive progress evidence is refused.

Each expensive runtime mode also repeats the short synthetic proof on its
assigned node before hashing source files or creating a run directory. This
closes the scheduler gap: committed evidence from one node cannot make a run on
another node expensive before that node proves the same capability. A failure
leaves no run directory and exits within minutes.

Capability aggregation is explicit and per-node. The operator-owned capability
dispatch creates one short Job targeted to each currently eligible non-Plex node
that advertises a free i915 resource. Committed evidence records the result for
each tested node. The platform is QSV-ineligible only when every eligible node
returns a complete semantic failure under a validated telemetry oracle. One or
more passing nodes keep the platform eligible; a `harness-blocked` node prevents
a cluster-wide ineligibility verdict until its measurement gap is resolved.

Expensive benchmark Jobs remain unpinned. If one lands on a node without a
passing proof, its assigned-node runtime check exits before source hashing or
run creation. The operator may redispatch without weakening the placement
boundary or treating that fast refusal as a benchmark result.

## 2. Benchmark harness corrections

### 2.1 Clip iteration

Every FFmpeg invocation in `benchmark.sh` and `stills.sh`, across quality,
savings, finalist, and contention modes, receives `-nostdin`. The quality loop
must process all three stable clip IDs for each encodable sample, and the
savings loop must process every panel title. A regression fixture contains
`detail`, `dark`, and `motion`, and its FFmpeg substitute consumes standard
input unless `-nostdin` is present. A separate multi-title savings fixture
proves that no FFmpeg child can drain later panel records. These fixtures detect
the original behavior rather than only counting configured keys.

### 2.2 Decode validation

The decode check maps only the primary video stream and explicitly excludes
audio, subtitles, and data. Source/output probes continue to validate audio
track count, subtitle count, and chapter count independently. A multi-stream
fixture with a PGS subtitle proves that subtitle encoder selection cannot make a
valid video decode fail.

### 2.3 HDR oracle

Quality variants use two references:

- the copied clip supplies duration and stream-layout expectations; and
- the original title probe supplies HDR static metadata expectations.

The output must match the original title's HDR mode, color fields, mastering
display, and MaxCLL/MaxFALL evidence. A clip that does not expose static SEI
metadata cannot erase the title-level expectation. Tests cover a clip with
missing static metadata, a matching encoded output, and a deliberately missing
or changed output value.

### 2.4 x265 reference scope

The two operator-selected grain samples carry explicit
`x265Reference: true` metadata. Offline validation requires exactly one AVC and
one HDR10 reference and rejects the marker on detection-only entries. Only
those samples run the initial x265 sweep, extensions, and comparison output.

QSV still runs on all six encodable titles. Invalid QSV rows remain preserved
as evidence and never cause x265 extension.

### 2.5 Metrics

The accepted VMAF harmonic mean and one-percent-low calculations remain
unchanged. Isolated zero-score frames remain visible and can reject a variant.

## 3. Test strategy

Each production change follows red-green-refactor. Before production code is
edited, a focused test must fail for the expected live defect:

1. The capability result rejects ICQ fallback.
2. The capability result rejects absent or non-increasing telemetry.
3. The capability result rejects absent, non-finite, or non-positive progress.
4. Runtime modes reject pending or insufficient committed evidence before
   mutation.
5. The assigned-node runtime proof runs before source hashing and run creation.
6. Three configured clips produce three complete setting sweeps even when the
   FFmpeg substitute would consume standard input.
7. A PGS-bearing output passes video-only decode while stream-count validation
   remains active.
8. HDR validation uses the title-level static metadata oracle.
9. x265 runs only for the two explicitly marked grain samples.

Tests assert observable commands, rows, artifacts, and refusal boundaries. They
do not assert that one helper called another helper. Each regression must be
shown failing before its minimal production fix.

Scoped verification is the benchmark Bats suite followed by
`mise exec -- just kube encode-benchmark-validate`. Before each PR, run
`mise exec -- just ci`.

## 4. Rollout and decision flow

### PR A: capability gate

- Strengthen the capability proof and result contract.
- Mark old committed evidence `pending`.
- Add dispatch and assigned-node runtime refusal checks.
- Add the capability and refusal regression tests.

After PR A merges and Flux reconciles, the operator runs the targeted capability
Jobs on every eligible node.

- If the telemetry interface itself cannot be validated, record the capability
  result as `harness-blocked`; do not make a QSV eligibility verdict or restart
  the quality sweep.
- If every eligible node returns a complete proof that fails for another reason,
  record QSV as ineligible and stop Task 4. Do not restart the quality sweep.
- If at least one node passes, commit the per-node non-secret capability evidence
  and proceed. Assigned-node proof still guards every expensive Job.

### PR B: harness corrections

- Add `-nostdin` coverage and process all three clips.
- Correct video-only decode validation.
- Add the title-level HDR oracle.
- Add explicit x265 reference markers and enforce their scope.
- Replace the execution plan's runtime expectation with an evidence-based range.

After PR B and capability-evidence changes merge, verify Flux source identity,
rerun preflight, and dispatch a fresh quality run ID. The old run remains a
separate failed-run artifact and is never resumed.

## 5. Runtime expectation

The corrected run is not expected to finish in 2–3 hours. The failed run
measured the four initial Goodfellas x265 points at roughly 4.5 hours for one
90-second clip. Three Goodfellas clips alone can require about 13.5 hours before
metric and still-generation overhead. The implementation plan must calculate a
new range from all observed per-variant times and verify that the Job's 36-hour
deadline remains credible before dispatch.

## 6. Authority and artifact handling

All cluster mutations remain operator-run. Agents may inspect cluster status,
logs, and persisted artifacts with scoped credentials. Source changes go through
feature-branch PRs and operator merge gates.

The failed run directory remains intact for regression evidence. Deleting the
stopped Job removed its node-local scratch only; no original media was modified.

[drm-usage-stats]: https://docs.kernel.org/gpu/drm-usage-stats.html
