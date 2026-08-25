# Repository Command Lifecycle

## Purpose

Audit the repository's current command surface, derive the workflow profiles that its
commands actually implement, and standardize comparable workflows without forcing unlike
operations into one universal sequence.

This specification supports
[GitHub initiative #298](https://github.com/supermorphic/homelab-talos/issues/298).
Current executable source, repository policy, and operating documentation remain
authoritative while implementation is active and after this specification becomes
historical.

The governing rule is:

> Standardization means comparable operations use the same semantic terminology and
> lifecycle conventions. It does not mean every operation must expose the same sequence
> of commands.

## Audit basis

The design is derived from current executable behavior, not from recipe names or the
candidate taxonomy that preceded this audit. The audit covered:

- the root Justfile and the repository, Talos, bootstrap, Kubernetes, test, and CI Just
  modules;
- all 108 suites and every campaign in `tests/catalog.yaml`;
- catalog validation, reachable-verifier analysis, scoped RBAC comparison, campaign
  orchestration, result coordination, and command-focused tests;
- repository policy in `AGENTS.md`;
- root and subsystem README files, testing references, setup guides, and operational
  runbooks;
- GitHub protection check, plan, and apply behavior;
- Talos maintenance-mode and live apply behavior;
- first-time and application bootstrap transactions;
- scoped and operator-published campaigns;
- Secret, identity, certificate, public-material, and credential workflows;
- integration, end-to-end, conformance, resilience, measurement, diagnostic, and cleanup
  workflows; and
- validator, verifier, probe, render, generate, status, and administrative scripts.

The catalog currently contains 40 offline validations, 31 live verifications, 15 smoke
suites, 5 integrations, 2 end-to-end suites, 8 resilience suites, 2 conformance suites,
2 diagnostics, and 3 measurements. Every cataloged verification is declared
non-mutating with no confirmation. Every cataloged integration, end-to-end, resilience,
and conformance suite is declared mutating and has a command-level or exact confirmation.

Those declarations are evidence, not proof by themselves. The audit also followed the
runner commands to their implementation scripts and checked their reachable operations.

## Findings

### Existing architecture

The repository already has a coherent safety philosophy with several useful command
shapes:

- Local validators compose into the cluster-independent `just ci` gate.
- Live verifiers use observer or bounded diagnostic access and normally need no
  accidental-execution confirmation.
- GitHub protection exposes separate check, plan, and apply commands because its plan is
  useful for administrative review.
- Talos repeats live inspection and a real target-system dry-run inside the same apply
  command because splitting those checks would create stale-state risk.
- Bootstrap commands combine validation, preflight, confirmation, activation, wait,
  verification, and safe recovery where the transition permits it.
- Tests create or disrupt bounded state, record evidence, and clean up or recover.
- Secret and credential workflows write repository artifacts under purpose-specific
  names because `apply` would hide their plaintext and encryption boundaries.
- Scoped campaigns coordinate observation. Published campaigns coordinate tests and
  persistent report publication. Their safeguards correctly differ.

This architecture should be standardized by comparable family, not replaced with a
single `plan -> confirm -> apply` interface.

### Genuine current inconsistencies

Repository inspection found the following current mismatches.

1. **Local repository validation uses live-observation terminology.**
   `just repo verify`, public `verify-files`, and private `verify-shell-scripts` inspect
   only repository, source, toolchain, shell, and secret-policy state. They belong to the
   local-validation profile.
2. **The scoped campaign has a static confirmation with no useful binding.**
   `TEST_SCOPED_CAMPAIGN_CONFIRM=run-local:scoped-verification` identifies only the
   campaign. It does not bind revision, plan digest, membership, credential scope, or
   target. It supplies accidental-invocation friction but neither authority nor proof
   that a displayed plan was reviewed.
3. **`ntfy-verify` has an intentional mutation path.**
   Its normal path is observational, but
   `NTFY_VERIFY_PUBLISH_CONFIRM=publish:ntfy-verify` sends three real notifications. The
   catalog still classifies the command as non-mutating verification. A command cannot
   be both the canonical observer verifier and a positive publish experiment.
4. **Published campaign confirmations do not consistently bind the reviewed plan.**
   Campaigns that include the Plex node-reboot scenario bind source revision and plan
   digest. Other published campaigns use only `run-publish:<campaign>`, even though the
   plan computes and displays the same revision, ordered membership, and digest. The
   weaker token proves deliberate campaign selection, but not review of the plan that
   will run and publish.
5. **One live administrative mutation has no confirmation guard.**
   `grafana-admin-reset` changes Grafana database state through a pod exec and then
   verifies API authentication. It is operator-run, but unlike comparable administrative
   recovery commands it has no operation-and-target confirmation.
6. **Two bootstrap recovery paths stop before the family postcondition.**
   `flux-adopt-cilium` restores its staged source edit on failure but does not re-suspend
   the live Cilium Kustomization after it has been resumed. `bootstrap retry-join`
   initiates the recovery reboot but returns before proving the requested etcd join and
   healthy membership. Comparable bootstrap transactions re-suspend on failed acceptance
   or wait for their stated recovery result.
7. **`talos apply-live` does not read back convergence.**
   It repeats validation, secure target inspection, and the no-reboot dry-run before
   applying, but it returns after `talosctl apply-config`. Comparable live reconciliation
   commands read back the resulting invariant when the target remains available.

These are behavior or safety mismatches within comparable families. They are not a
request for broad visual symmetry.

## Model

### Effects come first

Classify a command by what it can do before selecting its name:

| Effect | Meaning |
| --- | --- |
| Local or source read | Inspect repository files, renders, schemas, policy, generated output, or local evidence. |
| Live or external read | Observe a cluster, service, repository setting, or another external target. |
| Worktree or local artifact write | Create or update tracked or ignored generated output, credentials, reports, ciphertext, or public material. |
| Live reconciliation | Change an existing cluster, application, or external administrative target. |
| Initialization or activation | Establish state that does not yet exist, or activate intentionally suspended state. |
| Experiment or disruption | Create, change, interrupt, or remove bounded temporary state to obtain evidence. |
| Publication | Persist already-produced evidence for other consumers. |
| Targeted deletion | Remove specifically identified temporary or run-owned state. |

A command can have several effects. Its primary name describes the result requested by
the caller. The effects determine the workflow profile and safeguards.

### Primary semantic vocabulary

The audit justifies five primary lifecycle terms:

| Term | Canonical meaning |
| --- | --- |
| `validate` | Prove local source, configuration, schema, policy, generated-output, or evidence correctness. |
| `verify` | Observe live or external state and prove an invariant without intentionally changing that target. |
| `apply` | Reconcile an existing target when a generic reconciliation verb is clearer than a purpose-specific action. |
| `bootstrap` | Perform exceptional initialization, first activation, or tightly related recovery. |
| `test` | Conduct a controlled experiment that may create, alter, disrupt, or remove bounded state. |

Each term remains because it distinguishes materially different effects and safeguards:
local assurance, live assurance, existing-state reconciliation, exceptional
initialization, and experimental evidence.

The following concepts are not peer-level primary terms:

- `check` is a specialized form of live or external verification, normally reporting
  drift or compliance. `github-protection-check` remains clear.
- `plan` is an optional stage that previews a later operation. It is not an operation
  family and is not a synonym for dry-run.
- `preflight` and `dry-run` are safeguards or stages.
- `cleanup` is a transaction stage and deletion effect. It remains a valid standalone
  purpose-specific command when targeted removal is the requested result.
- an artifact writer is an effect profile, not a lifecycle verb. Secret, identity,
  certificate, report, render, and generation commands keep purpose-specific names.
- `resilience` is a disruptive subtype of `test`.

Purpose-specific verbs such as `status`, `diagnostics`, `probe`, `render`, `generate`,
`publish`, `refresh`, `sync`, `restart`, `reset`, and `cleanup` remain valid when they
describe the requested result more precisely. Their actual effects still select the
workflow profile.

When an approved semantic rename occurs, all repository-owned consumers change
atomically. The old command is removed. There is no deprecated alias or dual terminology.

## Accepted workflow profiles

### 1. Local validation

Canonical semantic term: `validate`.

```text
local inputs
-> validation
-> pass or actionable failure
```

Expected properties:

- no live-cluster credential requirement;
- no intended live or external mutation;
- no confirmation;
- deterministic local renders, reports, caches, or formatter fixes may be produced when
  the command says so; and
- assertions use an independent oracle or encode a genuine invariant.

Purpose-specific `lint`, `scan`, and `render` names are valid within this profile when
they describe the mechanism or output. They do not change the local-validation meaning.

### 2. Live or external observation

Canonical semantic term: `verify`; specialized read views may use `check`, `status`,
`diagnostics`, or `observe`.

```text
bounded access
-> observe current target
-> prove or report an invariant
```

Expected properties:

- no intentional target-state change;
- no ordinary accidental-execution confirmation;
- least-privilege observer or bounded diagnostic access where repository policy permits;
- no fallback to broader credentials after a permission failure; and
- evidence or ignored local credential artifacts may be written only when their bounded
  side effect is explicit and the observed target remains unchanged.

A negative authorization probe can remain observational only when denial is the asserted
result and the credential or target guarantees that the attempted operation cannot
persist. A positive path that deliberately creates state belongs to `test`.

### 3. Existing-state reconciliation and administration

Canonical generic term: `apply`. A precise action such as `sync`, `reset`, `restart`, or
`publish` may be better when reconciliation is not the caller's actual request.

```text
[plan and/or preflight when useful]
-> required authority
-> [confirmation proportional to consequence]
-> apply or precise administrative action
-> post-verification
```

Expected properties:

- safety-critical preconditions are repeated immediately before mutation;
- a standalone plan exists only when it has independent review or reuse value;
- embedded preflight or dry-run is preferred when separation would make checks stale;
- material confirmation binds meaningful operation or target context;
- reliable read-back proves the requested result; and
- an unavailable immediate oracle is documented as a deferred verification gate rather
  than silently treated as success.

GitHub and Talos can conform to this same profile with different interfaces:

```text
GitHub:
check -> plan -> authorize -> confirm -> apply -> read-back

Talos maintenance-mode install:
unconfirmed apply -> embedded preflight + real dry-run + refuse
confirmed apply -> repeat preflight + apply -> deferred bootstrap preflight

Talos live change:
unconfirmed apply-live -> embedded preflight + real dry-run + refuse
confirmed apply-live -> repeat preflight + apply + read-back convergence
```

### 4. Exceptional initialization and recovery

Canonical semantic term: `bootstrap` for initialization and activation. Precise recovery
actions such as `retry-join`, `reboot`, `resize`, or `adopt` remain appropriate.

```text
validation or preflight
-> required authority
-> confirmation proportional to consequence
-> initialize, activate, or recover
-> wait
-> verify
-> rollback or safe containment on failure when available
```

Expected properties:

- the transaction starts from an explicitly checked initial or suspended state;
- target and source identity are checked before mutation;
- app activation repeats deployed-source and live-suspension checks;
- acceptance is part of the transaction or an explicit next bootstrap gate;
- failed app activation re-suspends the Kustomization while preserving resources; and
- destructive initialization is not automatically rolled back when rollback would be
  less safe than stopping at a documented recovery boundary.

Separate `bootstrap-plan` commands are not required. The first Talos bootstrap exposes a
useful standalone `preflight` and later `verify` because etcd formation and node joining
are asynchronous. Application bootstraps correctly embed the same concepts in one
transaction.

### 5. Controlled experiments and tests

Canonical semantic term: `test`. `resilience`, `conformance`, `probe`, and benchmark
commands are subtypes or purpose-specific interfaces selected by actual effects.

```text
preflight
-> required authority
-> confirmation proportional to risk
-> run-owned experiment or disruption
-> evidence assertion
-> cleanup or recovery
-> validate retained result
```

Expected properties:

- every mutation is bounded by target, ownership labels, run ID, or equivalent identity;
- state-changing shared-cluster tests use the repository Lease where required;
- confirmation binds the operation and target, with stronger binding for disruption;
- cleanup and recovery outcomes remain distinct from the primary assertion outcome;
- failed cleanup is visible and never broadens deletion scope; and
- disruptive resilience tests document and prove recovery.

Read-only smoke suites use the observation profile even though the interface is named
`test smoke`. Mutating measurements and probes use the controlled-test profile even
though their purpose-specific names do not contain `test`.

### 6. Artifact creation and local setup

This is an effect profile with purpose-specific names, not a sixth primary lifecycle
verb.

```text
validate inputs and capability
-> [external preflight or bounded test]
-> [confirmation proportional to consequence]
-> stage artifact or local setup change
-> validate
-> atomically install
```

Expected properties:

- plaintext and encryption boundaries remain explicit;
- secret values never enter logs or unencrypted tracked files;
- tracked output is encrypted or public by design;
- temporary external state used to validate credentials is owned and cleaned;
- writes are staged and atomically installed when practical; and
- operator ownership follows access to plaintext, the age identity, or an external
  credential source, not the presence of a confirmation variable.

### 7. Targeted removal

This is also an effect profile with purpose-specific `cleanup` commands, not a primary
lifecycle verb.

```text
resolve exact owned target
-> [confirmation proportional to consequence]
-> delete only that target
-> verify absence
```

Cleanup must bind a run, resource, namespace, UID, or similarly narrow identity. It must
not expand to broad selectors or credentials when the expected target is absent.

## Complete command-family mapping

The table maps every major current family to the accepted profile. Representative names
are used instead of duplicating the executable recipe inventory.

| Current family | Profile and canonical terminology | Expected safeguards | Audit result and required change |
| --- | --- | --- | --- |
| `just ci`, Kubernetes `*-validate`, Talos source/generated validation, test/catalog/result validation, links, policy, schema, lint, and scans | Local validation; use `validate` for assurance aggregates | No live credentials, no confirmation | Conforms except the repository aggregate and helpers. Rename `repo verify`, `repo verify-files`, and private `verify-shell-scripts` atomically to `validate` terminology. |
| Kubernetes and application `*-verify`, named access verifiers, `bootstrap verify`, Talos `volume-status`, Pi-hole status, read-only smoke, status, diagnostics, and non-mutating probes | Live/external observation; `verify`, specialized `check`/`status`/`diagnostics` | Bounded read or diagnostic access, no ordinary confirmation, no credential fallback | Conforms except the positive notification branch in `ntfy-verify`. Split that branch into a cataloged mutating test. The ignored kubeconfig refresh in the pre-Cilium `bootstrap verify` is a bounded bootstrap handoff and does not change the observed target. |
| GitHub protection check/plan/apply | Existing-state reconciliation; `check` is drift verification, `plan` is review, `apply` is mutation | Admin authority, repository-bound confirmation, apply-time recheck, read-back | Conforms. The separate plan has review value; the apply reads back effective protection. No rename or shape change. |
| Talos `apply` | Existing-state reconciliation with destructive installation transition | Live disk/Secure Boot checks, true dry-run, disk-serial target binding, repeated checks; later bootstrap preflight | Conforms. Full verification is deliberately deferred until all rebooting installs can be checked together before etcd bootstrap. Keep the same-command preview/apply design. |
| Talos `apply-live` | Existing-state reconciliation | Secure target check, no-reboot dry-run, target-bound confirmation, repeated checks, post-readback | Add post-apply convergence verification. Keep the same-command preview/apply interface. |
| First Talos/etcd bootstrap, Cilium, Flux, foundation, storage, and application bootstrap | Exceptional initialization/activation | Initial-state and deployed-source checks, exact confirmation, wait, acceptance, safe containment | The ordinary app bootstrap transactions conform. Keep their names and embedded lifecycle. |
| `flux-adopt-cilium` and `retry-join` | Exceptional adoption/recovery | Same as comparable bootstrap recovery, including safe failure containment and requested recovery proof | Add live re-suspension to failed Cilium adoption after resume. Make join retry wait for and verify the requested etcd recovery. |
| Bootstrap `reboot` and `resize-longhorn` | Purpose-specific exceptional recovery; disruptive subtype where applicable | Exact node binding, health preflight, one-node scope, wait, full recovery | Conforms. Their stronger recovery gates justify their specialized shape. |
| Scoped campaign | Orchestrates the live-observation profile | Worktree/source/context/credential/catalog/permission preflight; local evidence; no fallback | Remove the static confirmation. Keep plan optional. Freeze and display revision, ordered membership, and digest in the run itself. |
| Operator-published campaigns and resume | Orchestrate the strongest member profile plus publication | Plan, source/Flux identity, plan-bound confirmation, Lease for mutating membership, evidence, guarded publication/resume | Bind every new published campaign confirmation to campaign, source revision, and plan digest. Keep the extra just-in-time Talos target confirmation for the Plex reboot. Resume remains run-ID-bound. |
| Secret manifests, ntfy identity/password, provider credentials, Homepage/platform integration credentials | Artifact creation | Plaintext and age capability checks, meaningful target confirmation, staged encryption, atomic install, leak checks | Conforms. Keep purpose-specific names; do not rename to `apply`. Credential validation may use a bounded external test that cleans itself. |
| Pi-hole CA and other public-material refresh | Artifact creation | External identity check, operation/target confirmation, certificate validation, atomic write, rollout stamp | Conforms. `refresh` accurately describes the requested artifact result. |
| Talos `generate`, render commands, report/summary generation, `tools`, `hooks`, and `talos kubeconfig` | Artifact creation or local setup | Explicit output boundary, validation, atomic install where relevant | Conforms. These are not live reconciliation even when they write ignored local state. |
| `ntfy-consumer-sync` | Existing-state administration with purpose-specific `sync` | Deployed-source and live-readiness checks, secret capability, target-bound confirmation, test-before-save, post-readback | Conforms. The name accurately describes application-owned state synchronization. |
| `grafana-admin-reset` | Existing-state administrative recovery with purpose-specific `reset` | Operator authority, target-bound confirmation, live preflight, post-authentication verification | Add the missing confirmation guard. Keep the command name. |
| Integration, end-to-end, conformance, Flux canary/connectivity/storage/persistence/alert tests | Controlled tests | Exact/command confirmation, run ownership, Lease where shared, evidence, cleanup | Conforms. Keep `*-test`, integration, E2E, and conformance names. |
| Resilience and node/pod restart scenarios | Disruptive controlled tests | Strong operation/target confirmation, shared Lease, recovery evidence, cleanup | Conforms. `resilience` remains a test subtype, not a peer verb. |
| Encode benchmark runs and the diagnostic evidence reader | Controlled tests and test-support stages | Run/sample binding, deployed-source checks, confirmations for created Jobs, retained evidence, cleanup | Conforms. A diagnostics-named helper that creates a collector Job belongs to the test transaction, not the observation profile. |
| Probes and measurements | Observation when read-only; controlled test when cataloged mutating | Catalog effect metadata, bounded credentials, run-owned state and cleanup when mutating | Conforms. `probe` describes measurement, while metadata selects the safety profile. |
| qbit_manage debug cleanup, encode benchmark cleanup, Sonobuoy teardown, and other run cleanup | Targeted removal | Exact run/resource binding, confirmation for material standalone cleanup, ownership/UID checks, absence verification | Conforms. Keep purpose-specific cleanup names. |
| Test report publication | Existing-state publication stage | Finalized-run validation, run-bound confirmation, exact target, post-readback/persistence evidence | Conforms. `publish` is more precise than generic `apply`. |

## Safeguards and stages

Safeguards remain orthogonal to the profile and command name.

| Stage or safeguard | Meaning | Required, optional, or inappropriate |
| --- | --- | --- |
| validation | Prove source, inputs, schema, policy, or evidence correctness | Required before relying on affected local inputs; may be embedded. |
| preflight | Prove current prerequisites before a consequential operation | Required when stale or wrong-target state could make mutation unsafe; standalone only when independently useful. |
| plan | Describe intended later work from current inputs | Optional; expose only when review or reuse has real value. Never authorization. |
| dry-run | Exercise the real operation or target validation path without persisting the intended mutation | Required when the target supports a meaningful dry-run and consequence warrants it; not a substitute for plan. |
| confirmation | Bind deliberate intent to useful operation, target, revision, or plan context | Inappropriate for ordinary observation; proportional for mutation, disruption, deletion, or publication. |
| operator authorization | Policy authority to perform the operation | Determined by repository policy and credential scope, never by naming or confirmation. |
| post-verification | Read back and prove the requested result | Required for material changes when a reliable immediate oracle exists; otherwise an explicit deferred gate. |
| rollback or containment | Restore prior state or stop reconciliation after failed acceptance | Required when safe and supported; destructive initialization may have a documented stop boundary instead. |
| cleanup | Remove bounded temporary or run-owned state | Required for experiments that create such state; failure remains visible. |

### Plan is not dry-run

A plan tells the caller what a later operation intends to do. A dry-run exercises the
real operation path or target-system validation without persisting the intended change.

Talos is the current public apply family with a true target-system dry-run. GitHub
protection and campaigns produce plans. Kubernetes server-side dry-run used by a bounded
diagnostic or test helper validates an API path; it does not create a peer plan command.

### Confirmation is not authorization

```text
operator authorization
-> policy authority to perform an operation

confirmation token
-> deliberate-intent or target/plan-binding execution guard
```

An agent-authorized operation can contain a confirmation guard. An administrative live
mutation can require both explicit operator authorization and confirmation. A static
token provides only accidental-execution friction; it must not be described as proof of
authority or plan review.

Confirmation strength is proportional to consequence:

- bounded temporary tests bind operation and target;
- run cleanup binds the exact run or owned resource;
- administrative repair binds operation and external target;
- a published campaign with a reviewable plan binds campaign, source revision, and plan
  digest; and
- destructive Talos actions bind the intended node and live hardware or recovery target.

## Proposed current-state refactors

This specification proposes the following atomic implementation scope.

### Repository validation terminology

Rename:

- `just repo verify` to `just repo validate`;
- `just repo verify-files` to `just repo validate-files`;
- private `verify-shell-scripts` to `validate-shell-scripts`; and
- catalog `validation.repo-verify` and scenario `verify` to
  `validation.repo-validate` and scenario `validate`.

Update every repository-owned recipe dependency, CI reference, test, variable, README,
guide, runbook, and command example in the same change. Do not leave aliases or deprecated
terminology.

### Observational ntfy verification

Keep `ntfy-verify` observational. Remove its optional positive publish branch and the
instruction that enables it.

Expose the three-message positive path as a purpose-specific `ntfy-publish-test` in the
controlled-test profile. Register it as mutating, require an exact confirmation that
binds ntfy and the tested topics, and update the ntfy operations guide and focused tests.

Denied publish attempts remain valid verifier assertions because denial is the expected
result and no target mutation can persist.

### Scoped and published campaigns

Remove `TEST_SCOPED_CAMPAIGN_CONFIRM`. Keep `scoped-campaign-plan` as an optional preview.
The actual scoped run repeats preflight, freezes and displays revision, ordered
membership, and plan digest, runs only with worktree-scoped credentials, retains results
locally, and never falls back to broader credentials.

For every operator-published campaign, make the plan-generated confirmation bind:

```text
campaign + source revision + plan digest
```

The campaign run recomputes those inputs before mutation. Campaigns containing the Plex
node-reboot test retain their additional target-specific Talos confirmation. Resume keeps
its existing immutable campaign-run-ID confirmation.

### Administrative and recovery safeguards

Add an exact operation-and-target confirmation to `grafana-admin-reset`. Keep its current
post-reset API authentication proof.

Make failed `flux-adopt-cilium` restore both sides of the staged transaction: revert the
worktree source edit and re-suspend the live Cilium Kustomization if this invocation
resumed it. Preserve existing resources.

Make `bootstrap retry-join` wait for and verify the requested member join, healthy member
set, and absence of relevant etcd alarms before returning success.

After `talos apply-live`, perform a bounded secure-API convergence read-back. Do not split
its embedded dry-run and apply flow into separate recipes.

## Commands explicitly unchanged

The following families were audited against their accepted profile and already conform:

- GitHub protection keeps `check`, `plan`, and `apply` because each stage has distinct
  review and reconciliation value.
- Talos maintenance-mode `apply` keeps its fail-safe same-command dry-run and apply shape;
  full verification remains the explicit pre-etcd bootstrap gate after all nodes reboot.
- Ordinary application bootstrap recipes keep embedded validation, source/suspension
  checks, exact confirmation, wait, verification, and re-suspension on failure.
- First etcd bootstrap keeps separate preflight and verification because cluster
  formation and node joining are asynchronous.
- Kubernetes and application `*-validate` commands already describe local assurance.
- Observational `*-verify`, status, check, and diagnostics commands other than the ntfy
  mixed path already avoid intentional target mutation.
- Secret, identity, certificate, public-material, render, generate, report, and local
  credential workflows keep purpose-specific names because their output is an artifact,
  not target reconciliation.
- `ntfy-consumer-sync` keeps `sync` because it performs test-before-save reconciliation of
  application-owned settings.
- Integration, E2E, conformance, and resilience commands already declare mutation and use
  test-appropriate ownership, confirmation, evidence, recovery, and cleanup.
- Mutating probes and benchmark helpers keep purpose-specific names while using the test
  safeguards selected by catalog metadata.
- Run-specific cleanup and report publication keep their precise purpose-specific names
  and target-bound guards.

No other rename or lifecycle reshaping is proposed without a mismatch found by the
family-level audit.

## Future-command decision framework

A contributor adding or changing a command answers these questions in order.

1. **What can it affect?** Record local reads, live reads, worktree or credential writes,
   live mutation, external administration, disruption, publication, and deletion.
2. **Which accepted profile matches the requested result?** Choose local validation,
   live observation, existing-state reconciliation, exceptional bootstrap/recovery,
   controlled test, artifact/setup, or targeted removal.
3. **Which term is canonical in that profile?** Use `validate`, `verify`, `apply`,
   `bootstrap`, or `test` when it states the result accurately. Use an established
   purpose-specific verb when it is more precise.
4. **Which safeguards match the consequence?** Decide validation, preflight, plan,
   dry-run, confirmation, post-verification, rollback, and cleanup independently. Do not
   add a stage only for visual symmetry.
5. **Who owns execution?** Apply `AGENTS.md` authority and credential rules separately
   from naming and confirmation.
6. **Which existing family is comparable?** Match its terminology, confirmation strength,
   lifecycle placement, evidence, and recovery unless a concrete target-specific reason
   requires a difference.

New terminology is not introduced when an accepted term or purpose-specific convention
already describes the operation.

## Repository invariants

The resulting convention establishes these standards:

1. `validate`, `verify`, `check`, `plan`, `preflight`, and `dry-run` do not persist the
   intended target-state mutation.
2. `verify` is observational toward its target. Use `test` when positive evidence requires
   deliberate temporary target mutation.
3. Local validation does not require live-cluster credentials.
4. Generic existing-state reconciliation uses `apply`; initialization uses `bootstrap`;
   tests and disruptions are classified as controlled experiments even when a more
   precise subtype appears in the command name.
5. A standalone plan exists only when it provides independent review or reuse value.
6. Confirmation guards for material consequences bind meaningful operation, target,
   revision, run, or plan context.
7. Operator authorization comes from repository policy and available capability, not
   from command naming or a confirmation variable.
8. Consequential operations repeat safety-critical preconditions immediately before
   mutation rather than trusting an earlier preview.
9. Material mutations use immediate post-verification when a reliable oracle exists, or
   name an explicit deferred gate when it does not.
10. Failed scoped permission checks never trigger broader-credential fallback.
11. Experiments and cleanup operate only on run-owned or exactly identified state and
    expose cleanup or recovery failure.
12. An approved semantic rename updates all repository-owned consumers atomically and
    leaves no alias or parallel terminology.
13. New terminology or workflow shape requires a behavioral or safety distinction, not
    visual symmetry.

## Durable documentation placement

Create a concise `docs/reference/repository-command-lifecycle.md` as the current durable
reference. It will document:

- the five primary semantic terms;
- the accepted workflow profiles;
- stages and safeguards;
- authority versus confirmation;
- the future-command decision framework;
- representative profile examples; and
- repository invariants.

Do not maintain a second manual inventory of every recipe. Source-adjacent README files,
the Just modules, and `tests/catalog.yaml` continue to own executable command details.

`AGENTS.md` remains limited to actual agent authority and safety rules. Add only concise
policy that agents must obey, such as observational verification, independent authority,
immediate precondition checks, and no credential fallback. Do not copy the taxonomy into
that file.

`docs/reference/testing-layers.md` and `tests/README.md` remain focused on test tiers,
evidence, and execution. They should reference the lifecycle document where needed rather
than becoming the repository-wide command-semantics authority.

## Mechanical enforcement

Use current catalog metadata and focused behavior tests. Do not build a generalized shell
command linter or duplicate the command catalog.

The catalog validator will require:

- every `verification` tier entry to declare `mutates_cluster: false` and
  `confirmation.type: none`;
- scoped verification to remain non-mutating, non-disruptive, local-only, and composed
  only of eligible observer or diagnostic verifiers;
- mutating and disruptive classification to agree with resolved campaign membership;
- every mutating suite to retain command-level or exact confirmation metadata; and
- approved validation terminology in catalog IDs and runner commands.

The existing reachable-verifier and scoped-RBAC analysis remains the primary mechanical
check of verifier implementations and credential grants. Add focused tests for behavior
that generic reachability cannot prove:

- `ntfy-verify` cannot send positive notifications and the new ntfy publish test is
  cataloged as mutating and exactly confirmed;
- `repo validate` and `repo validate-files` are canonical, and no old command or alias
  remains;
- scoped campaigns need neither confirmation nor a prior plan, repeat all preflight, and
  cannot fall back to broader credentials;
- published campaign confirmation changes when source revision or plan membership
  changes;
- Grafana reset refuses before its target-bound confirmation and still proves
  post-reset authentication;
- failed Cilium adoption re-suspends live reconciliation and restores its source edit;
- join retry proves the requested member recovery before success; and
- live Talos apply proves post-apply convergence.

Confirmation quality, authority ownership, and selection of a primary or purpose-specific
verb remain review decisions. A keyword scanner cannot reliably prove those properties.

## Approaches considered

### 1. Universal lifecycle

Require every change to expose `plan -> confirm -> apply`.

This would make interfaces visually regular, but it would split Talos safety checks from
their mutation, manufacture bootstrap plans with no independent review value, rename
tests and artifact writers misleadingly, and increase stale-state risk. It is rejected.

### 2. Vocabulary and future guidance only

Document terms, fix the two previously known examples, and otherwise retain current
behavior.

This has the lowest immediate churn, but it leaves mixed observational/mutating verifier
behavior, inconsistent plan binding, and weaker recovery safeguards in current comparable
families. The convention would describe a state the repository does not meet. It is
rejected.

### 3. Profile-driven standardization

Derive a small vocabulary, group current commands by actual effects and safety needs,
standardize terminology and safeguards within each profile, and keep specialized shapes
when their target transitions differ.

This approach creates a standardized current state and a usable future convention. It
requires focused current refactors, but avoids repo-wide renaming and lifecycle ceremony.
It is the recommended design.

## Validation and completion criteria

Implementation will use focused tests for every changed contract and finish with
`mise exec -- just ci`. Cluster-independent validation must prove:

- repository validation uses only the new `validate` names and catalog metadata;
- all verification entries are observational and unconfirmed;
- positive ntfy publication exists only as a cataloged mutating test;
- scoped campaigns are autonomous through the supported scoped workflow and cannot use
  broader credentials;
- published campaign confirmation binds the plan that will execute;
- administrative and bootstrap recovery guards meet their profile contracts;
- Talos live apply has an independent post-apply convergence oracle;
- documentation links and current examples use the implemented terminology; and
- the canonical full CI gate passes.

Live cluster execution is not required for implementation tests when fixtures and command
stubs independently prove control flow. Later live execution follows current repository
authority policy and the relevant runbook.

Before merge, reconcile this specification with the implemented and validated result.
After merge, it becomes a historical record; material later redesign uses a new numbered
specification.

## Consequences

The repository retains multiple legitimate command shapes, but comparable operations use
the same semantics and safeguards. Contributors can classify a new command from its
effects, select one memorable profile, and add only the safeguards its consequences need.

The current command surface also becomes consistent with the convention: local assurance
uses validation terminology, live verification is observational, plans that gate
publication bind what will run, administrative mutation has proportional intent binding,
and bootstrap recovery returns only after reaching or safely containing its requested
state.

This is harmonized semantics with focused current repair, not a repo-wide naming cleanup.
