# Repository Command Lifecycle

Standardization means comparable operations use the same semantic terminology and
lifecycle conventions. It does not mean every operation exposes the same command
sequence.

## Primary terms

| Term | Meaning |
| --- | --- |
| `validate` | Prove local source, configuration, schema, policy, generated-output, or evidence correctness. |
| `verify` | Observe live or external state and prove an invariant without intentionally changing that target. |
| `apply` | Reconcile existing state when a generic reconciliation verb is clearer than a purpose-specific action. |
| `bootstrap` | Perform exceptional initialization, first activation, or tightly related recovery. |
| `test` | Conduct a controlled experiment that may create, alter, disrupt, or remove bounded state. |

These are the primary lifecycle terms because they distinguish local assurance, live
assurance, reconciliation, initialization, and experimentation. Other useful names fit
around them:

- `check` is a specialized verification form, usually for drift or compliance.
- `plan`, `preflight`, and `dry-run` are stages or safeguards, not peer operations.
- `cleanup` is a deletion effect and transaction stage. It remains a valid standalone
  command when targeted removal is the requested result.
- artifact writers are an effect profile, not a lifecycle verb.
- `resilience` and `conformance` are test subtypes.
- precise verbs such as `status`, `diagnostics`, `probe`, `render`, `generate`, `publish`,
  `refresh`, `sync`, `restart`, and `reset` remain valid when they state the requested
  result better than a primary term.

An approved semantic rename updates all repository-owned consumers atomically. Do not
retain a deprecated alias or parallel terminology.

## Workflow profiles

| Profile | Canonical terminology | Expected shape and safeguards |
| --- | --- | --- |
| Local validation | `validate`; precise `lint`, `scan`, or `render` where useful | Read local inputs, prove correctness, and return an actionable result. It needs no live credentials or confirmation. Explicit local outputs are allowed. |
| Live or external observation | `verify`; specialized `check`, `status`, `diagnostics`, or `observe` | Use bounded read or diagnostic access, do not intentionally mutate the target, require no ordinary confirmation, and never fall back to broader credentials. |
| Existing-state reconciliation and administration | `apply` or a precise action such as `sync`, `reset`, `restart`, or `publish` | Use plan or preflight when useful, obtain required authority, confirm in proportion to consequence, mutate, and read back the result. Repeat safety-critical checks immediately before mutation. |
| Exceptional initialization and recovery | `bootstrap`; precise recovery actions such as `retry-join`, `reboot`, `resize`, or `adopt` | Check the initial or suspended state, bind source and target, confirm, initialize or recover, wait, verify, and safely contain failure when supported. |
| Controlled experiments and tests | `test`; precise subtypes such as `resilience`, `conformance`, benchmark, or mutating probe | Bind temporary state to a run or target, use authority and confirmation proportional to risk, collect evidence, clean up or recover, and preserve cleanup failure separately. |
| Artifact creation and local setup | Purpose-specific names such as `generate`, `secrets`, `refresh`, `tools`, or `kubeconfig` | Validate inputs and capability, stage output, validate it, and install atomically when practical. Secret and encryption boundaries stay explicit. |
| Targeted removal | Purpose-specific `cleanup` | Resolve an exact run-owned or otherwise identified target, confirm when proportionate, delete only that target, and verify absence. Never broaden scope when the target is missing. |

A command can have several effects. Name it for the result requested by the caller, then
select its profile and safeguards from its actual behavior. Read-only smoke uses the
observation profile even though its interface says `test`; a mutating probe uses the
controlled-test profile even if its name does not contain `test`.

## Stages and safeguards

| Stage or safeguard | Meaning and use |
| --- | --- |
| validation | Prove source, input, schema, policy, or evidence correctness before relying on it. It may be embedded. |
| preflight | Prove current prerequisites before a consequential operation. Expose it separately only when it has independent value. |
| plan | Describe intended later work from current inputs. It is optional and is never authorization. |
| dry-run | Exercise the real operation or target validation path without persisting the intended mutation. Use it when the target supports a meaningful simulation. |
| confirmation | Bind deliberate intent to useful operation, target, revision, run, or plan context. It is inappropriate for ordinary observation. |
| operator authorization | Supply policy authority to perform the operation. This is independent of naming and confirmation. |
| post-verification | Read back and prove the requested result. Use an explicit deferred gate only when no reliable immediate oracle exists. |
| rollback or containment | Restore prior state or stop reconciliation after failed acceptance when that is safer than leaving the transaction active. |
| cleanup | Remove only bounded temporary or run-owned state and keep cleanup failure visible. |

A plan is not a dry-run. A plan explains what a later operation intends to do. A dry-run
exercises the real target-system operation path without persisting the intended change.
GitHub protection and campaigns produce plans. Talos `apply` and `apply-live` use true
target-system dry-runs.

Not every operation needs every stage. Embedded preflight is valid when a separate command
would add ceremony or create stale-state risk. A standalone plan is justified only when
it provides real review or reuse value.

## Confirmation and authority

Operator authorization is the policy decision that permits an operation. A confirmation
token is an execution-intent and target-binding guard. One does not imply the other.

An agent-authorized operation can contain a confirmation guard. A privileged live
mutation can require both explicit operator authorization and confirmation. Static tokens
provide only accidental-execution friction; material consequences should bind meaningful
context:

- bounded tests bind operation and target;
- cleanup binds the exact run or owned resource;
- administration binds operation and external target;
- published campaigns bind campaign, source revision, and plan digest; and
- destructive Talos operations bind the intended node and live hardware or recovery
  target.

Execution ownership comes from `AGENTS.md`, credential scope, and specific operator
authorization. It does not come from a command name or the presence of `*_CONFIRM`.

## Classify a new command

Answer these questions in order:

1. **What can it affect?** Record local reads, live reads, repository or credential
   writes, live mutation, external administration, disruption, publication, and deletion.
2. **Which workflow profile matches the requested result?** Choose local validation,
   live observation, existing-state reconciliation, exceptional bootstrap or recovery,
   controlled test, artifact or setup, or targeted removal.
3. **Which term is canonical for that profile?** Use a primary term when it states the
   result accurately. Otherwise use an established purpose-specific verb.
4. **Which safeguards match the consequence?** Decide validation, preflight, plan,
   dry-run, confirmation, post-verification, rollback, and cleanup independently. Do not
   add a stage for visual symmetry.
5. **Who owns execution?** Apply repository authority and credential rules separately
   from naming and confirmation.
6. **Which existing family is comparable?** Match its terminology, confirmation strength,
   lifecycle placement, evidence, and recovery unless a concrete target-specific reason
   requires a difference.

Do not introduce a new term or workflow shape when an accepted convention already
describes the operation.

## Representative examples

- `just repo validate`, `just ci`, and Kubernetes `*-validate` commands are local
  validation. They need no cluster credentials.
- Kubernetes `*-verify`, GitHub protection `check`, and application status or diagnostics
  are observational toward their target. A positive action that creates evidence belongs
  in a registered test instead.
- GitHub protection follows `check -> plan -> authorize -> confirm -> apply -> read-back`.
  Its separate plan has review value.
- Talos maintenance-mode `apply` embeds preflight and dry-run, then uses the later
  bootstrap preflight as its deferred verification gate. `apply-live` uses a preview
  dry-run, applies after confirmation, and uses a second dry-run as immediate convergence
  verification. Both conform to reconciliation without exposing identical interfaces.
- Application bootstrap embeds source and suspension checks, confirmation, reconciliation,
  acceptance, and failure re-suspension. First etcd bootstrap exposes separate preflight
  and verification because cluster formation is asynchronous.
- Integration, E2E, resilience, conformance, and mutating probes use run ownership,
  confirmation, evidence, cleanup, and recovery appropriate to their risk. Scoped
  observational campaigns need no confirmation and never fall back to broader credentials.
- Secret writers, certificate refresh, render, generation, and local credential setup keep
  precise artifact names. Run cleanup keeps `cleanup` and binds the exact owned target.

## Repository invariants

1. `validate`, `verify`, `check`, `plan`, `preflight`, and `dry-run` do not persist the
   intended target-state mutation.
2. `verify` is observational toward its target. Use `test` when positive evidence requires
   deliberate temporary mutation.
3. Local validation does not require live-cluster credentials.
4. Generic reconciliation uses `apply`; initialization uses `bootstrap`; experiments and
   disruptions use the controlled-test profile even when a precise subtype is named.
5. A standalone plan exists only when it provides independent review or reuse value.
6. Confirmation for material consequences binds meaningful operation, target, revision,
   run, or plan context.
7. Operator authorization comes from repository policy and available capability, not from
   naming or confirmation.
8. Consequential operations repeat safety-critical preconditions immediately before
   mutation rather than trusting an earlier preview.
9. Material mutation uses immediate post-verification when a reliable oracle exists, or
   names an explicit deferred gate when it does not.
10. A failed scoped permission check never triggers broader-credential fallback.
11. Experiments and cleanup operate only on run-owned or exactly identified state and keep
    cleanup or recovery failure visible.
12. An approved semantic rename updates every repository-owned consumer atomically and
    leaves no alias or parallel terminology.
13. New terminology or workflow shape requires a behavioral or safety distinction, not
    visual symmetry.

Executable Just modules, source-adjacent README files, and `tests/catalog.yaml` remain the
authority for individual commands. This reference defines shared semantics, not a second
manual command inventory.
