# 01 — Activate and read back `Protect main`

**What to build:** Make GitHub the effective production merge authority before
tracked repository guidance changes. Configure squash-only repository merging and
an active, no-bypass `Protect main` ruleset, then prove the complete effective
configuration through API read-back rather than trusting submitted settings.

**Blocked by:** None — can start immediately.

**Status:** needs-triage

- [x] Repository merge settings enable squash merging and disable merge commits
      and rebase merging.
- [x] One active ruleset named `Protect main` targets only `refs/heads/main` and
      has no bypass actors.
- [x] The ruleset requires a pull request with zero approvals, squash as the only
      permitted merge method, and none of the review options excluded by the spec.
- [x] The ruleset requires the GitHub Actions `ci` check with strict up-to-date
      enforcement.
- [x] Linear history is required, while force pushes and branch deletion are
      blocked.
- [x] Update restrictions, merge queue, required deployments, and required signed
      commits remain disabled.
- [x] Complete API read-back verifies repository merge settings, the full active
      ruleset, and the rules applying to `main`, including the empty bypass list
      and GitHub Actions source for `ci`.
- [x] No exported GitHub response or ruleset-ID-bound payload is committed.

## Comments

2026-07-31: Activated repository ruleset `Protect main` (ruleset ID `20116777`).
Authenticated API read-back confirmed squash-only repository merging, the exact
`main` ref condition, active enforcement, no bypass actors, GitHub Actions app ID
`15368` for strict required check `ci`, zero-review squash-only pull requests,
linear history, deletion protection, and non-fast-forward protection. The effective
branch rules contain no additional rule types. Implementation is complete and awaits
maintainer review.

2026-07-31: Follow-up review selected a tracked deterministic checker and guarded,
idempotent repair path. It resolves the current ruleset and GitHub Actions source at
runtime rather than retaining the initial ruleset ID or an exported response as
desired state.
