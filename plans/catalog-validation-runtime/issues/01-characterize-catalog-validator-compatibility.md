# 01 — Characterize the catalog validator compatibility boundary

**What to build:** An executable compatibility contract that locks the catalog
validator's externally observable behavior before its implementation changes. The
contract must exercise accepted catalogs, every existing negative fixture, and
multi-defect cases that prove which rejection wins under fail-fast evaluation.

**Blocked by:** None — can start immediately.

**Status:** needs-triage

- [x] The canonical catalog is accepted through the existing shell-facing command
      with its current standard output, standard error, and exit status.
- [x] Every existing negative fixture asserts its first rejection reason, output
      stream, and exit status rather than merely asserting that validation failed.
- [x] Compound invalid catalogs prove that rule ordering and deterministic
      fail-fast behavior remain part of the compatibility contract.
- [x] The compatibility checks cover all established catalog assertions without
      coupling tests to the validator's internal data structures.
- [x] The complete cluster-independent validation contract passes with all 32
      suites in their existing order.

## Comments

2026-07-31: Added a black-box Python compatibility contract invoked through the
existing shell test entrypoint. It locks canonical and currently accepted edge-case
behavior, every prior negative fixture, representative failures for each validator
rule family, exact output streams and statuses, late campaign/CI/Chainsaw rules, and
three compound fail-fast boundaries. `mise exec -- just ci` passed all 32 suites in
their established order after the contract was added.
