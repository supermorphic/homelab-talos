# 03 — Replace catalog validation with single-parse Python

**What to build:** The existing shell-facing catalog validation command backed by a
holistic Python validator. Each YAML manifest is parsed once per invocation, and the
shared in-memory representation is evaluated through the complete established rule
sequence without changing what contributors invoke or observe.

**Blocked by:** 01 — Characterize the catalog validator compatibility boundary.

**Status:** needs-triage

- [x] The shell-facing command, accepted arguments, standard output, standard
      error, exit statuses, and success message remain compatible.
- [x] The catalog and every referenced YAML manifest are parsed no more than once
      per validator invocation and reused across rule evaluation.
- [x] Every existing assertion executes in the established order and stops at the
      same first failure for the same input.
- [x] The executable compatibility contract passes for accepted catalogs, all
      negative fixtures, rejection reasons, output streams, exit statuses, and
      compound fail-fast cases.
- [x] Catalog and artifact-contract harness coverage remains intact; no fixture,
      assertion, suite, or diagnostic is weakened, removed, reordered, or skipped.
- [x] The complete cluster-independent validation contract passes with all 32
      suites in their existing order and without cluster-dependent access.

## Comments

2026-07-31: `catalog_validator.py` now implements ordered, single-parse validation
behind the retained shell entrypoint. The black-box compatibility contract and three
complete 32-suite post-refactor CI runs passed.
