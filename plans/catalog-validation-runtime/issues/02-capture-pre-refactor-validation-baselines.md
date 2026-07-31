# 02 — Capture pre-refactor validation baselines

**What to build:** A reproducible before-refactor performance report for the three
distinct validation boundaries: standalone catalog validation, the complete test
harness, and the full sequential validation contract. The report establishes the
comparison conditions and raw evidence needed to attribute later improvements.

**Blocked by:** None — can start immediately.

**Status:** needs-triage

- [x] Each validation boundary is measured three times under comparable machine,
      toolchain, cache, and network conditions.
- [x] The report records every command, individual duration, three-run median,
      outcome, and relevant environmental conditions.
- [x] The full sequential runs retain and report all 32 suites in their established
      order.
- [x] The report distinguishes catalog time, negative-fixture work, other harness
      work, Helm-related suites, and total sequential validation time using measured
      evidence.
- [x] Any skipped or unsuccessful measurement is reported with its reason instead
      of being silently omitted or replaced with an estimate.

## Comments

2026-07-31: Baseline commands, raw run IDs, individual measurements, medians,
environment, attribution, and exclusions are recorded in `validation-report.md`.
