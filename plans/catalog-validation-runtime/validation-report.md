# Catalog validation runtime report

Date: 2026-07-31

## Conditions and commands

All reported runs used the same Darwin arm64 workstation, the repository-pinned
toolchain, warm public chart/tool caches, and no cluster context. The recorded tools
included Chainsaw 0.2.15, Kubernetes/kubectl 1.35.6, and yq 4.53.3. Full runs used
the unchanged sequential 32-suite command:

```bash
mise exec -- just ci
```

Standalone catalog runs used:

```bash
mise exec -- /usr/bin/time -p \
  scripts/test/validate-catalog.sh tests/catalog.yaml
```

The complete-harness boundary is the `validation.test-harness` duration recorded by
each canonical full run. This avoids a second execution and uses the repository's
millisecond suite instrumentation. Every reported full run passed all 32 suites in
their established order.

## Before-refactor measurements

The three canonical baseline artifacts are from commit `8547d7a41638`. Their test
breadth predates the expanded black-box compatibility contract, so that expansion
makes the post-refactor comparison conservative rather than favorable.

| Run ID | Standalone catalog (s) | Harness (s) | Full sequential (s) | Helm-related suites (s) | Outcome |
| --- | ---: | ---: | ---: | ---: | --- |
| `20260730T040931Z-8547d7a41638-operator-f7ee7e56` | — | 245.401 | 300 | 29.247 | passed, 32 suites |
| `20260730T041441Z-8547d7a41638-operator-1cc3f017` | — | 245.710 | 297 | 26.649 | passed, 32 suites |
| `20260730T041946Z-8547d7a41638-operator-c4a431d9` | — | 246.669 | 297 | 26.151 | passed, 32 suites |
| **Median** | **19.54** | **245.710** | **297** | **26.649** | **passed** |

The standalone pre-refactor measurements were 19.42, 19.54, and 19.82 seconds on
the same machine immediately before replacement. Earlier process profiling measured
about 20.5 seconds for one catalog validation and about 153 seconds for the original
negative-fixture work, or about 173.5 seconds combined. Subtracting that measured
catalog work from the 245.710-second median leaves roughly 72.2 seconds of other
harness work. One validator run launched approximately 3,839 yq processes.

The Helm-related column sums the application validators that render or verify pinned
Helm sources. Its 26.649-second median confirms that chart work was not the dominant
recoverable cost.

## Post-refactor measurements

All post-refactor runs used the same uncommitted implementation tree based on
`5fa401e7cf77`; only generated run IDs and timestamps differed.

| Run ID | Standalone catalog (s) | Harness (s) | Full sequential (s) | Outcome |
| --- | ---: | ---: | ---: | --- |
| `20260731T165123Z-5fa401e7cf77-operator-7cf5c085` | 0.13 | 68.859 | 118 | passed, 32 suites |
| `20260731T165451Z-5fa401e7cf77-operator-f2603ad3` | 0.12 | 69.049 | 118 | passed, 32 suites |
| `20260731T165658Z-5fa401e7cf77-operator-938bdbc6` | 0.12 | 70.034 | 120 | passed, 32 suites |
| **Median** | **0.12** | **69.049** | **118** | **passed** |

The standalone median improved by about 99.4% (approximately 163 times faster), the
harness median by about 71.9% (3.56 times faster), and the full sequential median by
about 60.3% (2.52 times faster). The expanded compatibility contract itself measured
8.78–8.96 seconds after replacement; before replacement the same expanded contract
drove characterization-complete harness runs to 620–632 seconds.

## Threshold results and remaining profile

| Boundary | Target | Acceptable | Median | Result |
| --- | ---: | ---: | ---: | --- |
| Standalone catalog | at most 2s | at most 5s | 0.12s | target met |
| Complete harness | at most 60s | at most 90s | 69.049s | acceptable met; target missed by 9.049s |
| Full sequential | stretch at most 120s | initial at most 180s | 118s | stretch met |

Because the harness target was missed, representative remaining components were
timed without changing the contract:

- `ntfy-identity-test.sh`: 12.50 seconds, the largest measured single component.
- Expanded catalog compatibility contract: 8.78 seconds.
- Per-file ShellCheck pass: 6.18 seconds.
- Campaign coordinator test: 6.42 seconds.
- Chainsaw test lint loop: 1.11 seconds.
- Conftest policy pass: 0.15 seconds.
- Chainsaw YAML parse loop: 0.11 seconds.

The remaining harness cost is distributed rather than catalog-dominated. Any future
optimization should begin with the ntfy identity fixture and repeated process startup
in compatibility/ShellCheck. It should be proposed separately; this change does not
parallelize, cache final Helm renders, or skip suites.

## Equivalence and external context

The retained shell command now delegates to a holistic Python validator. It loads the
catalog once and each referenced Chainsaw YAML document once per invocation. The
black-box contract passed canonical acceptance, every prior negative fixture, exact
first rejection messages, stdout/stderr, exit statuses, campaign ordering, CI and
Chainsaw completeness, and compound fail-fast cases. The full command retained all
32 suites, order, secret-free operation, and cluster independence.

Comparable repositories are context only. The onedr0p cluster template's current
[Flate pull-request workflow](https://github.com/onedr0p/cluster-template/blob/main/.github/workflows/flate.yaml)
filters on changed Kubernetes files, while its
[QEMU cluster E2E workflow](https://github.com/onedr0p/cluster-template/blob/main/.github/workflows/template-e2e-cluster.yaml)
is a separate job. The onedr0p
[home-ops repository](https://github.com/onedr0p/home-ops) documents Talos, Flux,
mise, and GitHub Actions, but its current workflow directory does not expose an
equivalent always-run 32-suite local contract. Those designs are useful context but
their breadth is not comparable enough to use their elapsed times as a target.

## Excluded and unsuccessful measurements

- A characterization-complete pre-refactor CI run stopped at a Ruff formatting
  check after all behavioral harness tests passed. It was corrected and rerun; the
  failed run is not substituted for any baseline or post-refactor measurement.
- Pre-refactor runs with the expanded 47-fixture contract took 672 and 682 seconds.
  They are reported above as attribution evidence but are not mixed into the original
  three-run baseline because test breadth differs.
- One component-profile invocation could not access the uv cache in the sandbox. It
  was rerun with the normal approved cache access and only the successful timing was
  retained.

No required validation was skipped. No cluster-dependent check, chart/render cache,
per-application parallelism, change-aware skipping, or suite reordering was added.
