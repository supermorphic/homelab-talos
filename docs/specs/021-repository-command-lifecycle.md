# Repository Command Lifecycle

## Purpose

Comparable operations use consistent semantics and safeguards. A universal
`plan -> confirm -> apply` interface would separate live Talos checks from mutation,
create stale-state risk, and disguise tests and secret writers as reconciliation.
[Repository policy](../../AGENTS.md) owns execution authority; executable Just modules
and [the test catalog](../../tests/catalog.yaml) own syntax and membership.

## Effects and terminology

Classify what a command can affect before naming it: source/local reads, live reads,
artifact/credential writes, reconciliation, initialization, disruption, publication, or
exact-target deletion. The requested result selects the name; all effects determine
safeguards.

| Term | Contract |
| --- | --- |
| `validate` | Prove local source, configuration, schema, policy, generated-output, or evidence correctness. |
| `verify` | Observe live/external state and prove an invariant without deliberately changing the target. |
| `apply` | Reconcile an existing target when a generic verb is clearer than a precise action. |
| `bootstrap` | Exceptional initialization, first activation, or tightly related recovery. |
| `test` | Controlled experiment that may create, alter, disrupt, or remove bounded state. |

`check` specializes verification. `plan` previews later work; `preflight` and `dry-run`
are safeguards, not operation families. Purpose-specific verbs such as `status`,
`diagnostics`, `render`, `generate`, `publish`, `refresh`, `sync`, `reset`, and `cleanup`
remain appropriate when they state the result more precisely. Read-only smoke follows
the observation profile despite its `test` interface; a mutating probe follows controlled
test safeguards despite its measurement name. Approved renames update all owned consumers
atomically and remove the old command without an alias.

## Workflow profiles

Local validation needs no live credentials or confirmation. It can produce bounded
renders, reports, caches, or declared formatter fixes while retaining independent
assertions. Live observation uses bounded observer/diagnostic access without ordinary
confirmation or credential fallback. Evidence/local credential writes must be explicit
side effects that leave the observed target unchanged. Negative authorization probes are
observational only when denial is the asserted result and no operation can persist.
Positive state creation belongs to a test.

Existing-state reconciliation uses useful preflight/plan, required authority,
proportionate confirmation, mutation, and post-verification. Repeat safety-critical
conditions immediately before mutation. Split stages only when they provide independent
review/reuse value. A missing immediate oracle requires an explicit deferred gate rather
than an implied success. GitHub protection has a useful separate plan; Talos embeds live
checks and true target-system dry-run in its apply invocation to avoid stale state.

Bootstrap checks explicit initial/suspended state and source/target identity before
activation, waits for the requested result, and verifies or safely contains failure.
Failed application activation re-suspends reconciliation while preserving resources.
Destructive initialization stops at a documented boundary when rollback would be less
safe. First etcd formation exposes a later bootstrap gate because it is asynchronous;
ordinary adoption/recovery must prove their requested result before returning success.

Controlled tests bind every mutation to target/run ownership, confirm in proportion to
risk, collect evidence, and clean up or recover. Shared state-changing tests use the
renewable Lease. Primary assertion, cleanup, and recovery have separate outcomes; cleanup
failure cannot broaden deletion scope or erase negative evidence. Resilience proves
recovery explicitly.

Artifact writers retain precise names because plaintext, encryption, and generated-output
boundaries matter. Validate capability/inputs, stage output, verify it, and install
atomically where practical. Temporary external credential tests own and clean their
state. Secret values never enter logs or unencrypted tracked files. Authority follows
access to protected material, not a confirmation variable.

Targeted removal resolves an exact owned run/resource/UID, applies proportionate
confirmation, deletes only that target, and proves absence. Missing targets do not permit
broader selectors or credentials.

## Safeguards and authority

A plan explains intended work; a dry-run exercises the real operation or target validation
without persisting its intended change. Neither is authorization. Confirmation establishes
execution intent and meaningful target binding; repository policy and credential scope
establish authority independently. Static tokens supply only accidental-invocation
friction and cannot prove plan review.

Material bindings follow consequence: temporary tests bind action/target, cleanup binds
owned state, administration binds external target, published campaigns bind source and
plan digest, and destructive machine operations bind live target hardware or recovery
context. Embedded preflight is preferred when a separate stage would become stale.
Reliable immediate read-back is required where available; safe rollback/containment is
required where supported. An agent-authorized operation may still have a confirmation
guard, while privileged mutation may require both guard and explicit operator authority.

## Review and enforcement

For a new command, identify effects, choose the comparable workflow profile and precise
name, select necessary safeguards, and apply execution authority separately. Introduce
new terminology or a workflow shape only for a real behavioral or safety distinction.
Do not add stages merely for visual symmetry.

Catalog validation checks observation/mutation declarations, confirmation metadata,
campaign membership, and scoped access against reachable verifier operations and RBAC.
Focused tests prove transitions and guards that metadata alone cannot establish.
Naming and proportional confirmation remain review decisions; a keyword scanner cannot
prove them. Fixture success proves implementation control flow, not deployment or native
live acceptance.
