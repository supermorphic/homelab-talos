# 02 — Align repository workflows and guidance with GitHub CI authority

**What to build:** Give contributors and agents one consistent repository workflow:
commit-time staged hooks provide fast local feedback, GitHub runs the canonical
full validation for every pull request targeting `main`, protected squash merge is
the production boundary, and Flux reconciles only after that merge. Preserve the
existing validation contract while removing duplicate post-merge CI and subjective
agent lifecycle policy.

**Blocked by:** 01 — Activate and read back `Protect main`.

**Status:** needs-triage

- [x] The authoritative workflow runs for pull requests targeting `main` and for
      manual dispatch, with no push-to-`main` trigger and no path filters.
- [x] The stable required job and check name remains `ci`; superseded runs for the
      same pull request are cancelled.
- [x] CI checks out full repository history, installs repository-pinned tools, and
      invokes only `mise exec -- just ci` as its validation entry point.
- [x] Existing post-validation summaries and artifacts remain available as
      non-gating evidence.
- [x] The staged hook membership, exclusions, and staged-file scope remain
      unchanged; formatter edits block the current commit for review and restaging.
- [x] `just repo lint` remains the repository-wide hook command, and `just ci`
      remains the unchanged canonical full, cluster-independent, secret-free
      validation command.
- [x] No mandatory pre-push or post-commit validation and no additional CI command
      or validation layer is introduced.
- [x] Normal workflow documentation concisely explains staged hooks, feature-branch
      push, pull-request `ci`, protected squash merge, and Flux reconciliation,
      including why the merge candidate and squash result represent the equivalent
      source tree under strict up-to-date enforcement.
- [x] Agent instructions remain approximately 80 lines or fewer and retain the five
      Git/worktree boundaries, pinned-tool and guarded-cluster rules, secrets
      safety, Talos generation rules, and critical Flux/storage invariants.
- [x] Agent instructions no longer mandate local full CI, describe emergency
      direct-to-`main` procedures, or retain the lifecycle and handoff policy
      explicitly removed by the spec.
- [x] A human-facing guide records what was configured, where to inspect it, exact
      settings, complete verification, guarded recovery, safe functional
      verification, and limited ruleset-history retention.
- [x] Read-only check and plan recipes report drift, while an exactly guarded,
      idempotent apply recipe can update or recreate protection after explicit
      authorization and complete API read-back.
- [x] Offline tests cover expected-state comparison, recovery planning, unexpected
      effective-rule refusal, exact confirmation, and dynamic GitHub Actions source
      resolution; live GitHub checks remain outside `just ci`.
- [x] Existing documentation is corrected where it contradicts the authority model,
      without creating another general CI-policy document.
- [x] Structural inspection and the unchanged `mise exec -- just ci` regression seam
      pass without repository secrets, kubeconfig, age keys, cluster access, or live
      service access.

## Comments

2026-07-31: Structural inspection confirmed PR/manual-only triggers, no path filters,
stable `ci`, concurrency cancellation, full checkout, and the sole canonical
validation command. `AGENTS.md` is 69 lines. Repository-wide staged-hook lint and
all 32 ordered `mise exec -- just ci` suites passed without cluster or secret
access; canonical run ID
`20260731T110115Z-e8a86fda43aa-operator-8b0be5f9` records the local result.
Implementation is complete and awaits maintainer review.

2026-07-31: Follow-up review selected deterministic repository-owned verification
and recovery rather than prose-only UI reconstruction. Read operations need no
mutation approval; each guarded apply requires explicit authorization for that
invocation and refuses ambiguous effective state.
