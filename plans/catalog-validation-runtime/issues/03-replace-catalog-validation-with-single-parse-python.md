# 03 — Replace catalog validation with single-parse Python

**What to build:** The existing shell-facing catalog validation command backed by a
holistic Python validator. Each YAML manifest is parsed once per invocation, and the
shared in-memory representation is evaluated through the complete established rule
sequence without changing what contributors invoke or observe.

**Blocked by:** 01 — Characterize the catalog validator compatibility boundary.

**Status:** ready-for-agent

- [ ] The shell-facing command, accepted arguments, standard output, standard
      error, exit statuses, and success message remain compatible.
- [ ] The catalog and every referenced YAML manifest are parsed no more than once
      per validator invocation and reused across rule evaluation.
- [ ] Every existing assertion executes in the established order and stops at the
      same first failure for the same input.
- [ ] The executable compatibility contract passes for accepted catalogs, all
      negative fixtures, rejection reasons, output streams, exit statuses, and
      compound fail-fast cases.
- [ ] Catalog and artifact-contract harness coverage remains intact; no fixture,
      assertion, suite, or diagnostic is weakened, removed, reordered, or skipped.
- [ ] The complete cluster-independent validation contract passes with all 32
      suites in their existing order and without cluster-dependent access.
