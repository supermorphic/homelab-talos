# 04 — Prove end-to-end equivalence and runtime

**What to build:** A post-refactor validation report proving that the optimized
catalog validator preserves the complete production confidence contract and
improves the measured bottleneck. The report compares like-for-like before and
after runs, evaluates every stated runtime threshold, and identifies the next
measured bottleneck when a ceiling is missed.

**Blocked by:** 02 — Capture pre-refactor validation baselines; 03 — Replace catalog
validation with single-parse Python.

**Status:** ready-for-agent

- [ ] Standalone catalog validation, the complete test harness, and the full
      sequential validation contract each receive three comparable post-refactor
      runs with individual durations and medians.
- [ ] The full sequential command passes all 32 suites in the unchanged order and
      retains the established fail-fast and reporting behavior.
- [ ] Before and after medians are compared against the standalone target and
      acceptable ceiling, harness target and acceptable ceiling, and full-command
      initial and stretch targets from the specification.
- [ ] If any acceptable ceiling is exceeded, measured profiling identifies and
      reports the dominant remaining cost before any follow-up optimization is
      proposed.
- [ ] Comparable Talos and Flux GitOps repositories are used only as contextual
      evidence, with differences in validation breadth called out explicitly.
- [ ] The final report lists every command and outcome, any intentionally skipped
      validation with its reason, and confirms that no caching, parallelism,
      change-aware skipping, or cluster-dependent checks were introduced.
