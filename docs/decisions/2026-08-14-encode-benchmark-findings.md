# Encode benchmark findings — no-go

- **Status: Accepted.**
Date: 2026-08-14.
Branch: `fileflows-movie-encoding-strategy`.

Builds on these accepted records:

- [Movie encoding benchmark — design](2026-08-01-fileflows-movie-encoding.md)
- [Movie encoding benchmark storage contract — amendment](2026-08-06-encode-benchmark-storage-contract-amendment.md)
- [Encode benchmark quality-run correction — amendment](2026-08-14-encode-benchmark-quality-run-correction.md)

## 1. Decision

The FileFlows movie-encoding platform described by the accepted design is
**NO-GO**. It is not authorized for deployment.

The required engine was QSV HEVC with LA-ICQ. ICQ is not an accepted substitute.

Both eligible nodes showed positive i915 video-engine activity, positive
progress, successful decode, and successful VMAF availability. Both selected ICQ
and failed initialization/rate-control proof. Under the accepted predicate, the
cluster is therefore QSV-ineligible. The quality sweep was not restarted.

Run `20260813T221312Z-5a22cde6` is inadmissible for cohort findings because it
predates the corrected harness and contains invalid or suspect rows.

The available evidence does not produce recommended QSV settings, cohort savings
estimates, an x265 matched-quality verdict, a finalist visual verdict, or a Plex
contention result.

## 2. Retained reconnaissance

The census conclusions remain reconnaissance; they are not a deployment or
encoder recommendation. The Task 0 aggregate verification retained these
publish-safe counts:

| Aggregate | Verified value |
| --- | --- |
| Titles | 397 |
| Total size | 17.26 TiB |
| Cohort: unspecified | 1 title; 0.02 TiB |
| Cohort: AVC | 125 titles; 2.92 TiB |
| Cohort: Dolby Vision | 126 titles; 7.63 TiB |
| Cohort: HDR10 | 128 titles; 6.28 TiB |
| Cohort: other | 6 titles; 0.19 TiB |
| Cohort: VC-1 | 11 titles; 0.20 TiB |
| Lifecycle: unlinked | 393 |
| Lifecycle: active | 4 |
| Lifecycle: private-permanent | 0 |
| Lifecycle: public-awaiting-cleanup | 0 |
| Probe failures | 1 |

## 3. Authorized follow-up after acceptance and merge

Only after this record is accepted and merged, the operator may use the guarded
`encode-benchmark-clean` recipe to delete only these two run directories:

- `20260806T175355Z-57647486`
- `20260813T221312Z-5a22cde6`

After that cleanup, a separate pull request may remove the benchmark harness. It
must preserve all decision and review records.

Evaluating ICQ, software x265, AV1, a different driver or runtime, or new
hardware requires a new accepted decision. This record does not authorize an
alternative encoder strategy.
