# Movie Encoding LA-ICQ Evaluation

## Purpose

Determine whether Intel Quick Sync Video (QSV) HEVC with look-ahead intelligent
constant quality (LA-ICQ) could preserve acceptable movie quality and recover useful
storage before building a FileFlows platform.

The selected approach was a standalone, disposable benchmark. It answered the
quality-and-savings question without first deploying FileFlows, changing the Intel GPU
plugin, or giving an encoding workload write access to the movie library. A successful
benchmark could have informed a later FileFlows design. It did not itself authorize
FileFlows deployment or media replacement.

## Design choice

The benchmark used Flux-managed inert inputs and operator-dispatched Kubernetes Jobs.
The reconciled application contained scripts, a sample manifest, and a negative-priority
class, but no continuously running encoder. Job templates remained outside the rendered
Kustomization so reconciliation could not create benchmark Jobs by itself.

The harness separated two questions that require different samples:

- a seven-title quality panel used difficult material to reject weak settings; its
  Dolby Vision title was detection-only, so six titles were encoded; and
- a stratified savings panel used representative full titles to estimate catalog
  reduction after a quality setting had qualified.

Quality clips were stream copies of three pinned regions per encoded title: `detail`,
`dark`, and `motion`. The harness never substituted another title or timestamp at
runtime. Software x265 was a matched-quality comparator on only the grain-heavy AVC and
HDR10 reference titles, not a production candidate.

## Storage and safety contract

The media share was divided by mount boundary rather than trusted script behavior:

| Mount | Source boundary | Access | Purpose |
| --- | --- | --- | --- |
| `/media` | `media/movies` | Read-only | Movie sources only |
| `/out` | `benchmark` | Read-write | Run-scoped durable evidence |
| `/scratch` | Node-local `emptyDir` | Read-write | Temporary clips and encodes |

The Jobs could not see `media/tv` or `downloads`. Radarr and Plex could not see the
benchmark output tree. Clip sweeps and savings encodes were measured in scratch and
discarded. Only explicitly selected full-title finalists could be copied into a run's
durable `encodes/` directory.

The first storage budget was unschedulable because it exceeded the nodes' ephemeral
partition. The completed census and measured node limits produced the final contract:

| Control | Final value |
| --- | ---: |
| `emptyDir.sizeLimit` | 105 GiB |
| `ephemeral-storage` request | 105 GiB |
| `ephemeral-storage` limit | 110 GiB |
| Preflight free-space floor | 115 GiB |

Scratch held one encode output, not a copy of its source. The largest measured title was
88.18 GiB, so 105 GiB provided about 19 percent headroom while remaining below the
134.66 GiB node allocatable value. The 110 GiB limit bounded unexpected growth.

The free-space check did not bind a Job to the node it measured. That placement gap was
accepted because its consequence was bounded: the read-only source remained intact,
`emptyDir.sizeLimit` constrained the Job, and `backoffLimit: 0` prevented an automatic
retry. The negative-priority class made the benchmark yield to normal workloads at the
scheduler, but did not claim that kubelet eviction would always remove it first.

Every benchmark container ran as UID and GID `568`, without privilege escalation or a
service-account token, and dropped all Linux capabilities. GPU Jobs requested exactly
one i915 resource and used required anti-affinity against Plex. Jobs used
`restartPolicy: Never`, no backoff, and a finite active deadline.

## Identity and evidence

Each run used an explicit run ID and an immutable manifest written before measured work.
The manifest bound the image digest, script and sample hashes, encoder commands, source
paths and hashes, node and runtime identity, VMAF identity, and applicable sampling
inputs. Resume required exact identity equality. A changed script, source, image,
command, model, or runtime identity required a fresh run; failed attempts remained
visible and could not become completed candidates.

The capability proof used the same production QSV command path as measured variants. A
node passed only when evidence established all of these facts:

- the QSV device initialized;
- verbose encoder evidence selected exactly `LA-ICQ`;
- the FFmpeg process held the configured i915 render node;
- DRM fdinfo showed a positive video-engine busy-time delta;
- encode progress was finite and positive;
- the primary output video decoded; and
- the configured VMAF comparison ran successfully.

Missing or malformed telemetry and other unavailable oracles were `harness-blocked`, not
a platform verdict. A complete semantic failure under valid oracles was a failed
capability. Expensive stages required committed per-node evidence, then repeated the
short proof on the assigned node before source hashing or creation of a run directory.

## Corrected execution contract

The first quality attempt exposed harness defects and could not support a decision. The
corrected design retained the LA-ICQ eligibility requirement and added these invariants:

- every FFmpeg invocation used `-nostdin`, so a child process could not consume the
  remaining clip or title loop;
- decode validation mapped only the primary video stream, while separate probes retained
  audio, subtitle, and chapter-count checks;
- HDR static-metadata expectations came from the original title rather than a copied
  clip that might not expose the relevant SEI messages;
- x265 ran only for the two explicitly marked grain references;
- capability dispatch tested every eligible non-Plex node and preserved the difference
  between a platform failure and an unavailable oracle; and
- expensive work stopped before source hashing or artifact creation unless the assigned
  node passed the exact LA-ICQ proof.

The corrected harness never relaxed the VMAF thresholds, substituted ICQ for LA-ICQ,
discarded low frames, or reused results from a run made under the earlier contract.

## Evaluation gates

The requested QSV controls combined `-global_quality` values `20`, `22`, `24`, `26`,
and `28` with look-ahead and extended bitrate control. The runtime-selected mode, not
the requested flags alone, determined whether a row was LA-ICQ.

A setting qualified for a cohort only when every applicable clip independently met all
of these requirements:

| Criterion | Requirement |
| --- | --- |
| VMAF harmonic mean | At least 95 |
| VMAF one-percent low | At least 90 |
| Output validation | No failures |
| Selected rate control | Exactly `LA-ICQ` |
| Operator visual assessment | Passed for the candidate |

The quality result could not pool clips to hide a weak scene. The qualified setting with
the greatest measured reduction would have become the cohort setting.

Savings was measured on full titles and reported by cohort as median and interquartile
range. A median reduction of at least 25 percent was a go, 15 to 25 percent was marginal,
and less than 15 percent was a no-go. The x265 comparison used interpolation only after
its CRF curve bracketed the LA-ICQ point; an unbracketed point produced no verdict.

## Historical outcome

**Outcome: NO-GO for the LA-ICQ strategy.**

Both eligible nodes initialized the QSV path far enough to show positive i915 video
engine work, positive progress, successful decode, and VMAF availability. Both selected
`ICQ`, not the required `LA-ICQ`. Exact rate-control selection was a load-bearing
eligibility predicate, so the cluster was ineligible for this strategy and the corrected
quality sweep was not started.

The earlier quality run recorded 44 variants, including 25 QSV rows that selected ICQ.
It predated the corrected capability and harness contract, contained invalid or suspect
evidence, and was therefore inadmissible. It supplied no cohort setting, savings
distribution, x265 matched-quality result, visual finalist verdict, or Plex contention
result.

The completed census remained useful reconnaissance rather than deployment evidence:

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

These values corrected the original capacity estimates and justified the final scratch
budget. They did not recommend an encoder or authorize changes to any movie.

## Reconsideration boundary

The no-go was caused by an objective strategy predicate, not by missing quality judgment:
the evaluated platform did not select LA-ICQ. Reconsidering the same strategy requires a
materially different driver, runtime, or hardware condition that can plausibly provide
LA-ICQ, followed by fresh per-node proof under the corrected telemetry and execution
contract. Any new quality evidence must use a fresh run identity and the corrected
harness; the inadmissible run can never be repaired or reused.

ICQ without look-ahead, AV1, software x265 as a production engine, another runtime, or
new hardware is a distinct strategy and requires its own design. A later ICQ evaluation
does not retroactively satisfy the LA-ICQ requirement or change this no-go outcome.

## Consequences

The benchmark succeeded in its primary purpose by preventing a FileFlows deployment
before the required encoder path had proved eligible. No FileFlows workload, media
replacement policy, Plex deployment change, or alternative encoder received authority
from this design or its evidence.
