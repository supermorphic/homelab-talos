# FileFlows QSV HEVC ICQ anomaly diagnostics

- **Status: Accepted.** Approved by the operator on 2026-08-19.
Date: 2026-08-19.
Branch: `codex/fileflows-icq-diagnostics`.

Builds on these accepted records without revising them:

- [QSV HEVC ICQ movie-encoding evaluation — design](2026-08-15-fileflows-qsv-hevc-icq-evaluation.md)
- [FileFlows QSV HEVC ICQ evaluation — findings](2026-08-18-fileflows-qsv-hevc-icq-evaluation-findings.md)

## 1. Decision

Add one bounded diagnostic mode to the existing inert encode-benchmark harness.
Use it to determine the cause of:

1. repeatable exact-zero frame-level VMAF on five AVC or VC-1 clips; and
2. the unavailable HDR10 source static-metadata oracle.

The diagnostic produces evidence, not quality candidates. It does not change
the accepted ICQ settings, VMAF thresholds, completed quality rows, or rollout
sequence. It does not authorize another quality sweep, crop review, finalist,
x265, savings, contention, FileFlows deployment, or media replacement.

## 2. Evidence boundary

Quality run `20260817T233546Z-debc0498` and findings run
`20260818T214739Z-8bc2de3e` remain immutable historical evidence. The
diagnostic may use their sanitized identities and observations to choose its
bounded panel, but it must not resume, repair, replace, or reinterpret either
run.

The retained evidence establishes these starting observations:

- each affected clip has one exact-zero VMAF frame at the same frame index at
  ICQ 16 and ICQ 30;
- the affected indices are 1641, 523, 370, 781, and 798 respectively;
- adjacent VMAF frames are nonzero;
- all three HDR10 title probes reported null `masteringDisplay` and `maxCLL`;
  and
- every HDR10 output probe reported populated, title-specific values.

These observations select diagnostic inputs. They are not diagnostic verdicts.

## 3. Bounded panel

### 3.1 VMAF panel

Run only ICQ 16 and ICQ 30 for these existing 90-second clips:

| Sample | Clip | Observed zero-based frame index |
| --- | --- | ---: |
| `avc-clean-coco` | `motion` | 1641 |
| `avc-grain-memento` | `dark` | 523 |
| `avc-grain-memento` | `detail` | 370 |
| `vc1-fugitive` | `detail` | 781 |
| `vc1-fugitive` | `motion` | 798 |

This is exactly ten diagnostic encodes. Generate each source clip once and use
the same clip bytes for both settings.

### 3.2 HDR panel

Use one existing 90-second `detail` clip from each HDR10 quality title:

- `hdr10-clean-ministry`;
- `hdr10-grain-goodfellas`; and
- `hdr10-motion-john-wick-2`.

Create one ICQ 16 diagnostic output per title. ICQ 16 is a probe identity, not
a candidate selection. The three outputs test whether metadata behavior is
title-specific without repeating all settings or clips.

The complete diagnostic performs thirteen encodes. It does not enumerate the
quality panel or publish candidate evidence.

## 4. VMAF diagnostic contract

For each source clip and encoded output, record:

- file SHA-256 and byte size;
- decoded frame count;
- stream start time, duration, time base, and average frame rate;
- per-frame best-effort timestamp, packet duration, key-frame flag, and picture
  type for the observed frame and two frames on each side; and
- the current VMAF frame result for that same five-frame window.

Run these bounded comparisons for each observed frame:

1. the existing VMAF command unchanged;
2. VMAF after independently resetting both input timelines to
   `PTS-STARTPTS`; and
3. local SSIM and PSNR for source-to-output pairings at frame offsets -2
   through +2.

The offset comparison is diagnostic only. It must select frames explicitly by
decoded frame index and give each selected sequence a new zero-based timeline.
It must not silently repair the production VMAF command.

Record every offset result. An automatic classifier may select an offset only
when SSIM and PSNR independently select the same offset. Disagreement between
the metrics is unresolved evidence, not a tie to break.

Classify each affected clip as follows:

- **temporal alignment defect** when a nonzero offset consistently provides
  the best independent SSIM and PSNR match at both ICQ settings and the frame
  timeline evidence identifies the corresponding duplicate, drop, or timestamp
  discontinuity;
- **encoder or output defect** when zero-offset timelines agree, independent
  SSIM and PSNR both make the target the unique local minimum at both settings,
  no nonzero pairing corresponds to the timelines, and the source window
  decodes without an error or discontinuity;
- **VMAF measurement defect** when zero-offset timeline and independent SSIM
  and PSNR evidence remain locally consistent, the target is not their unique
  local minimum, and only VMAF reaches exact zero; or
- **unresolved** when the independent evidence does not satisfy one of these
  predicates.

Do not classify a cause from visual impression, one metric, or the repeated
frame index alone.

## 5. HDR static-metadata contract

The stream-level probe is not an authoritative absence oracle by itself. For
each source title, its stream-copy diagnostic clip, and its encoded output,
collect and normalize static metadata through both:

1. decoded-frame side data from bounded `ffprobe -show_frames` windows; and
2. HEVC mastering-display and content-light-level SEI parsed from bounded
   `trace_headers` output.

Probe the beginning, diagnostic-clip region, and final bounded window of each
source title. Each bitstream window begins at a decodable random-access unit
and ends after ten seconds or after both static-metadata messages are observed,
whichever comes first. Static metadata is authoritative only when the
decoded-frame and direct bitstream-syntax oracles agree and the normalized
values do not conflict across the three windows. The direct SEI syntax is the
genuine bitstream invariant; the decoded-frame view checks how the runtime
exposes it. Preserve exact rational values until final normalized comparison;
do not compare rounded display decimals.

The stream-copy clip is a control. It distinguishes a source-probe limitation
from metadata loss at the existing clip boundary. The encoded elementary
bitstream evidence distinguishes muxer presentation from encoder output.

Classify each title as follows:

- **source-probe defect** when the independent source oracles agree on
  populated values but the current stream-level probe reports null;
- **clip-boundary defect** when the title has authoritative values but the
  stream-copy clip loses or changes them;
- **encoder/output defect** when the source and clip agree but the encoded
  elementary stream omits or changes the values;
- **preserved** when all authoritative source, clip, and encoded values match;
  or
- **unresolved oracle** when source oracles are absent, conflicting, or vary
  across the bounded windows.

`preserved` is diagnostic evidence only. It does not convert any historical
HDR10 row into a pass.

## 6. Harness and artifact contract

Add a `diagnostics` mode to the existing harness rather than a parallel tool.
It uses strategy `qsv-hevc-icq-v1`, a diagnostic manifest schema, and a
diagnostic result schema that cannot resume or feed quality, candidate, or
findings modes.

The manifest binds:

- exact source identities and clip timestamps;
- the five observed frame indices;
- ICQ settings 16 and 30 for the VMAF panel and ICQ 16 for the HDR panel;
- exact encode, frame-probe, VMAF, SSIM, PSNR, and bitstream-trace commands;
- script, image, FFmpeg, libvmaf, QSV, node, kernel, and i915 identities; and
- the accepted findings decision digest and historical run IDs used to define
  scope.

Retain the manifest, sanitized command identities, normalized JSON evidence,
per-comparison metrics, and a terminal diagnostic summary under one immutable
run directory. Keep media outputs in bounded scratch and discard them after
durable evidence publication. Do not commit media, live infrastructure
identifiers, or raw unsanitized logs.

Use a four-hour active deadline, the existing non-Plex GPU placement rules,
the existing read-only movie and writable output mounts, no service-account
token, non-root execution, equal i915 request and limit, and fail-closed image
and source identity checks.

## 7. Dispatch, monitoring, and authority

Dispatch requires passing committed capability evidence, deployed-source
agreement, and preflight. Before mutation, preflight also proves that the
deployed FFmpeg exposes `trace_headers`, `libvmaf`, `ssim`, and `psnr` and that
the deployed ffprobe supports the required bounded frame fields. Dispatch then
requires this exact confirmation:

```text
run:encode-benchmark:diagnostics
```

After this decision is accepted and the implementation is merged and
reconciled, an agent may mint task-scoped credentials and dispatch, monitor,
collect, and clean up its reversible diagnostic resources under `AGENTS.md`.
Cleanup remains exact-run scoped. Persistent Flux changes go through Git.

While a diagnostic Job is active, monitor through one established sanitized
results command at two-hour intervals. A scheduled check never authorizes a
dispatch, retry, or cleanup. Stop the schedule when the Job is terminal,
operator input is required, or the diagnostic goal completes.

## 8. Failure and retry behavior

An unavailable required command, malformed manifest, source drift, image
drift, incomplete frame window, missing metric, or conflicting oracle produces
`harness-blocked` evidence. An encode or decode failure is retained as failed
diagnostic evidence. Neither state becomes an encoder verdict by default.

Do not retry automatically. Diagnose the retained failure first. A correction
that changes commands, scripts, source identity, image identity, or oracle
semantics requires a fresh run ID.

## 9. Test and validation contract

Implementation follows test-driven development. Required tests prove:

1. the diagnostic panel is exactly ten VMAF encodes plus three HDR encodes;
2. no other setting, sample, clip, or downstream mode is reachable;
3. frame windows and offsets are bounded and use explicit zero-based pairing;
4. classification requires the stated independent evidence;
5. HDR normalization retains exact rationals and requires frame/bitstream
   agreement;
6. diagnostic artifacts cannot resume or feed quality or findings;
7. confirmation, deployed-source, capability, source, image, mount, resource,
   and cleanup guards remain active; and
8. historical run artifacts are never opened for mutation.

Run the focused Bats suites, then:

```text
mise exec -- just kube encode-benchmark-validate
mise exec -- just ci
```

## 10. Terminal findings

Create a separate Draft findings decision after one admissible diagnostic run.
It must dispose of both anomaly classes and choose exactly one next action:

- recommend fresh `qsv-hevc-icq-v1` quality evidence under a corrected contract;
- close `qsv-hevc-icq-v1` and recommend a separate strategy decision; or
- record the exact unresolved evidence and required operator input.

The findings decision cannot authorize a quality run or replacement strategy.
Either requires a later accepted decision. Historical quality rows and the
95/90 thresholds remain unchanged in every outcome.

## 11. Operator decision

The operator accepted this diagnostic contract on 2026-08-19. Acceptance
authorizes implementation and the bounded diagnostic workflow above. It does
not authorize another quality run, FileFlows deployment, media replacement,
or evaluation of another encoding strategy.
