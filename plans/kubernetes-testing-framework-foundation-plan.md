# Kubernetes Testing Framework — Reviewed Foundation Plan

## Context and outcome

`homelab-talos` currently has roughly 5.5k lines of validation and verification
logic embedded inline in Justfiles. An earlier
`plans/talos-validation-refactor-plan.md` proposed extracting offline
`*-validate` Bash into `scripts/validate/` behind thin `just` wrappers. This
reviewed plan incorporates that work and is the single canonical go-forward plan
for validation, live verification, smoke, E2E, resilience, and conformance
testing.

The repository also has useful live coverage that must be preserved during the
migration: `qbittorrent-killswitch-verify`, Gatus VPN monitoring, and the
qBittorrent `PrometheusRule`.

Chainsaw is a good fit for ordered Kubernetes assertions, cleanup, and reports,
but it is not by itself proof that a network path never leaked. Specialized
probes and recorded evidence remain necessary for properties such as continuous
VPN and DNS isolation.

This plan delivers the reusable framework foundation. It is intentionally not a
claim that robust workload E2E testing is complete: that requires the subsequent
qBittorrent smoke, leak-sentinel, VPN interruption, Pod recovery, and disruption
scenarios described under "Required follow-up sequence."

## Decisions

1. **Chainsaw is the go-forward live-scenario engine.** Existing live recipes
   remain until equivalent Chainsaw scenarios and probes pass repeatedly and
   produce reviewable evidence.
2. **Heavy Justfiles are reduced in staged, reviewable steps.** Offline
   validators move first, live verification logic second, and scenario semantics
   change only after mechanical extraction is proven.
3. **`just` remains the only public operator interface.** It performs guards and
   dispatch only; scenario and probe logic lives outside Justfiles.
4. **The foundation contains one genuinely read-only proof test.** It validates
   the harness, not the full E2E security contract.
5. **Every live test executes once.** Chainsaw emits one JUnit report; the runner
   creates summary and environment JSON independently. Tests are never rerun
   solely to obtain another report format.
6. **Offline Chainsaw validation prefers the binary's own offline path.** Chainsaw
   ships a real `chainsaw lint` command and a `chainsaw export schemas` command;
   there is no `chainsaw schema-lint`, and `chainsaw test --no-cluster` is not used
   as lint because cluster operations fail while local scripts may run. Phase 1
   confirmed that pinned Chainsaw 0.2.15 lints both configuration and test input
   with a deliberately nonexistent kubeconfig and no cluster access. It is the
   primary offline check, so no extra JSON-Schema validator dependency is added;
   `chainsaw export schemas` is retained only for editor/IDE wiring.
7. **Production smoke tests name an existing namespace explicitly.** They must
   not cause Chainsaw to create an ephemeral namespace.
8. **No continuous-leak claim is accepted until probe placement is explicit.**
   A workstation-side process or intermittent `kubectl exec` sampling alone
   cannot prove continuous behavior inside a Pod network namespace.
9. **Conftest is the offline semantic-policy engine.** Rego is reserved for
   collection-wide or cross-file invariants where it replaces shell iteration
   and provides native unit tests. Thin Bash continues to orchestrate
   `helm template`, `kustomize build`, and CLI input/output; readable,
   application-specific configuration snapshots may remain Bash/yq. Policies
   use pinned Conftest, OPA v1 syntax (`import rego.v1`), and positive and
   negative tests. Chainsaw remains the live-scenario engine.
10. **Smoke read-only safety is machine-enforced.** Conftest rejects any smoke
    scenario with missing dispatch labels, outside `flux-system`, or without
    `spec.concurrent: false`. It rejects mutating operations in step
    try/catch/finally/cleanup, test-level catch, and configuration-level
    `spec.error.catch`. The runner also requires a non-empty JUnit test count so
    selector drift cannot produce a vacuous green live run.
11. **Live test identity uses fixed axes.** Public commands use
    `just test <tier> <target> [scenario]`; every live target is explicit, the
    optional scenario position is smoke-only, and target/scenario names are not
    aliases. `all` remains reserved until it genuinely dispatches every
    registered target. Result metadata records the same identity.

## Architecture

| Responsibility | Location | In `just ci`? | Engine |
|---|---|---:|---|
| Offline source/render orchestration | `scripts/validate/` | Yes | Thin Bash + pinned CLIs |
| Offline semantic policy and unit tests | `tests/policy/` | Yes | Conftest + Rego |
| Specialized live checks not suited to Chainsaw | `scripts/verify/` | No | Guarded Bash and pinned CLIs |
| Test dispatch, safety, locking, results | `scripts/test/` | Offline portions only | Bash |
| Live scenario definitions and test-local assets | `tests/chainsaw/` | Schema only | Chainsaw |
| Specialized network/API probes | `tests/probes/` | Unit tests only | Python/Bash as justified |
| Controlled fixtures | `tests/fixtures/` | Validation only | Declarative data |

The `*-validate` versus `*-verify` boundary from `AGENTS.md` remains strict:

- Offline validation, schema checks, ShellCheck, and future probe unit tests may
  run in `just ci`.
- Smoke, E2E, resilience, status, preflight, and diagnostics require a live
  cluster and remain operator-only.
- Every live health check or mutation is reached through a guarded `just` recipe.
- No test decrypts SOPS files or reads secret values into results.

Shared code is deliberately small. `scripts/lib/common.sh` may contain error
formatting, the Bash version guard, and repository-root discovery. Do not build a
shell assertion framework: cross-file and collection-wide YAML policy belongs in
`tests/policy/`, while simple app snapshots may stay local to their validator.
Live Kubernetes helpers stay under `scripts/test/`. Cleanup traps remain explicit
in each top-level runner so a generic helper cannot silently replace an existing
trap or hide cleanup failure.

## Delivery: PR sequence

This foundation is large; it must **not** land as one diff. Ship as an ordered
sequence of small PRs, each passing `just ci` on its own:

1. **PR 1 — 0A mechanical:** extract inline `*-validate` bodies into
   `scripts/validate/*.sh` behind thin wrappers; add `scripts/lib/common.sh`.
   Behavior-preserving; no policy change.
2. **PR 2 — 0A policy foundation:** pin Conftest; add tested Rego for the
   semantic media tag/`dependsOn`/gateway/capability/PVC policy; preserve existing
   Bash rendering and readable app-specific snapshots.
3. **PR 3 — tooling + layout:** pin Chainsaw/ShellCheck (+ schema validator only if
   needed), `.gitignore`, `mod test`, `tests/` + `scripts/test/` scaffolding, and
   `scripts/test/validate-chainsaw.sh`; wire `just test validate` into `ci`.
4. **PR 4 — dispatch/evidence + proof test:** `run-chainsaw.sh`, safety/locking,
   diagnostics, results handling, the read-only `flux-ready` proof test, and the
   opt-in diagnostics self-test.
5. **PR 5 — 0B live-verify extraction:** last and highest-risk (see below).

The order lets each PR be reviewed and reverted independently; scenario work
begins only after PR 4 proves the harness.

## Phase 0A — Mechanical offline-validation extraction

Extract every current inline `*-validate` body from `kubernetes/mod.just` into
`scripts/validate/<name>.sh`, leaving thin recipe wrappers.

This step is behavior-preserving:

- Keep assertion semantics, invocation order, render inputs, and output messages
  unchanged initially.
- Extract orchestration without introducing a general-purpose shell assertion
  library. Missing render/build inputs should normally fail through the owning
  pinned CLI rather than duplicate `assert_file`/`assert_wired` helpers.
- Do not combine the mechanical move with a new tag policy, a new media-wide
  policy, or changed `dependsOn` semantics.
- Keep `kubeconform` repo-wide rather than duplicating it per application.
- Run every offline validator and `just ci` before changing policy behavior.

After the extraction is green, add stricter semantic policy in a separate
Conftest/Rego commit:

- Reject mutable image tags such as `latest`, `main`, `master`, `stable`, and
  `nightly`.
- Use subset semantics for `dependsOn` unless exact membership is an explicit
  invariant.
- Preserve existing behavior-critical rendered assertions; migrate them to
  Conftest incrementally when cross-resource policy provides a concrete benefit.
- Add the media-wide capability, gateway, image-pinning, and PVC policy.
- Add native Rego unit tests that prove descriptive failures for at least:
  mutable or missing image tags, `RollingUpdate` with an RWO PVC, unauthorized
  `NET_ADMIN`, missing dependency, and public gateway exposure.

Run `conftest verify` in `just ci`. Prefer inline `with input as ...` cases; keep
declarative fixture files only when a realistic object is clearer than inline
test data. Use explicit or all-namespace policy evaluation so a package mismatch
cannot silently select the default `main` namespace and report zero policies.

This reverses the earlier decision to defer OPA. The scope is intentionally
narrow: SOPS encryption checks remain in `scripts/check-sops-encrypted.sh`,
schema validation remains kubeconform, rendering stays thin Bash, and Chainsaw
owns live behavior.

## Phase 0B — Live-verification extraction and classification

Reduce the remaining heavy `*-verify` recipes without pretending every live
check belongs in Chainsaw:

1. Mechanically move specialized CLI workflows, diagnostic collection, and
   existing live checks into `scripts/verify/<name>.sh`.
2. Leave thin, guarded `just kube <name>-verify` wrappers so the operator
   interface and safety boundary remain unchanged.
3. Classify each extracted check:
   - Kubernetes resource readiness and status assertions → future Chainsaw smoke.
   - User-visible functional workflows → future Chainsaw E2E plus probes.
   - Failure and recovery workflows → future guarded Chainsaw resilience tests.
   - Cilium/Talos/Helm diagnostic commands → remain focused verification scripts.
4. Preserve `qbittorrent-killswitch-verify` until the new VPN suite proves
   behavioral parity. Do not weaken or delete it during foundation work.

Cluster-dependent parity runs must be reported as operator-run or skipped; they
must not be added to `just ci`.

**0B ships last (PR 5) and is the highest-regression-risk phase:** moving live
`*-verify` bodies gets only ShellCheck coverage in CI — the actual behavior is
exercised solely by operator runs. Therefore each extracted recipe requires a
**hard merge gate**: an operator parity run of that recipe against the live
cluster (or an explicit, recorded skip) before its PR merges. Do PR 5 only after
the harness (PRs 1–4) is proven, and consider splitting it per-recipe if the diff
is large.

Ship Phase 0B as per-recipe slices. **PR 5a starts with
`metrics-server-verify`:** mechanically move its body to
`scripts/verify/metrics-server.sh` without changing the public command or its
behavior. Classify the Kustomization, Deployment, and APIService readiness checks
as future Chainsaw smoke assertions; classify `kubectl top nodes` as a read-only
functional probe that remains in the verification script until equivalent
scenario coverage passes repeatedly. The live
`mise exec -- just kube metrics-server-verify` parity run is the hard merge gate
for this slice.

**PR 5b continues with `csi-driver-smb-verify`:** mechanically move its body to
`scripts/verify/csi-driver-smb.sh` behind the same thin, guarded wrapper without
changing the public command or its behavior. Every check it performs — the
`csi-driver-smb` Kustomization Ready, the `csi-smb-controller` Deployment and
`csi-smb-node` DaemonSet rollouts, and the `smb.csi.k8s.io` CSIDriver
registration — is a read-only Kubernetes resource readiness/status assertion, so
all of them classify as future Chainsaw smoke assertions; the slice adds no
functional probe or destructive step. The live
`mise exec -- just kube csi-driver-smb-verify` parity run is the hard merge gate
for this slice.

**PR 5c continues with `media-storage-verify`:** mechanically move its body to
`scripts/verify/media-storage.sh` behind the same thin, guarded wrapper without
changing the public command or its behavior. Both checks — the `media` and
`media-storage` Kustomizations Ready and the static RWX `media/media-data` PVC
Bound — are read-only resource readiness/status assertions, so they classify as
future Chainsaw smoke assertions (the eventual SMB suite); the slice adds no
functional probe or destructive step, and the documented hardlink proof in
`docs/phase-11-media.md` remains the real mount exercise. The live
`mise exec -- just kube media-storage-verify` parity run is the hard merge gate
for this slice.

**PR 5d continues with `intel-gpu-plugin-verify`:** mechanically move its body to
`scripts/verify/intel-gpu-plugin.sh` behind the same thin, guarded wrapper without
changing the public command or its behavior. The `intel-gpu-plugin` Kustomization
Ready and the DaemonSet rollout classify as future Chainsaw smoke assertions; the
`gpu.intel.com/i915` allocatable-resource count is a read-only node-capability
probe (dependent on the Talos `siderolabs/i915` extension and real `/dev/dri`
hardware) that remains in the verification script until equivalent scenario
coverage passes repeatedly. The slice adds no destructive step. The live
`mise exec -- just kube intel-gpu-plugin-verify` parity run is the hard merge gate
for this slice.

## Phase 1 — Pinned tooling and offline schema validation

- Pin Chainsaw 0.2.15 through `aqua:kyverno/chainsaw` and refresh `mise.lock`.
- Pin ShellCheck 0.11.0 through the mise registry.
- Keep the Conftest version introduced in Phase 0A pinned and locked; it embeds
  the OPA runtime used by the repository policies.
- Do not add a separate JSON Schema validator: Decision 6 confirms the pinned
  Chainsaw lint path is cluster-free. Reconsider only if standalone
  StepTemplates require schema coverage that the pinned binary cannot provide.
- Keep the existing pinned `kubeconform`, `kubectl`, `helm`, `kustomize`, `yq`,
  and other repository tools.
- Defer Python/`uv` until the first real network or API probe is implemented.
- Add `/.test-results/` to `.gitignore`.
- Register `mod test "tests"` in `.justfile`.

`scripts/test/validate-chainsaw.sh` performs offline test validation:

1. Run the confirmed cluster-free `chainsaw lint` over the configuration and
   every conventionally named `chainsaw-test.yaml`/`chainsaw-test.yml`. Parse all
   scenario YAML separately so referenced resources cannot contain malformed
   YAML. Reconsider exported-schema validation only if standalone StepTemplates
   are introduced and pinned Chainsaw cannot lint them directly.
2. Parse referenced YAML files.
3. Run ShellCheck on repository test scripts.
4. Never invoke live test steps or local scenario scripts.

Either way the check derives from the pinned executable, so test syntax and the
runtime cannot silently drift.

## Phase 2 — Repository layout

Create:

```text
scripts/
├── lib/
│   └── common.sh
├── validate/
│   └── <validator>.sh
├── verify/
│   └── <live-check>.sh
└── test/
    ├── run-chainsaw.sh
    ├── validate-chainsaw.sh
    ├── safety/
    │   └── require-chaos-confirmation.sh
    ├── diagnostics/
    │   ├── collect.sh
    │   └── environment.sh
    └── lib/
        ├── k8s.sh
        └── results.sh

tests/
├── mod.just
├── README.md
├── policy/
│   └── media/
│       ├── media.rego
│       └── media_test.rego
├── config/
│   └── chainsaw.yaml
├── chainsaw/
│   ├── smoke/
│   │   └── cluster/
│   │       └── flux-ready/
│   ├── e2e/
│   └── resilience/
├── probes/
└── fixtures/
```

Repository-level runners live under `scripts/`; declarative tests, test-local
probes, and fixtures live under `tests/`. This avoids a second nested scripts
hierarchy and eliminates brittle relative sourcing such as
`tests/scripts/lib/../../scripts/lib/common.sh`.

## Phase 3 — Safety, execution, and diagnostics

### Safe dispatch

`scripts/test/run-chainsaw.sh` accepts an explicit tier and target, plus an
optional registered scenario for smoke, and:

- Allows only registered targets and scenarios; target and scenario names are
  not aliases, and no arbitrary path or shell argument is forwarded.
- Verifies `kubeconfig` exists for live tiers.
- Creates an atomic single-run lock for state-mutating E2E/resilience tests and
  refuses concurrent execution.
- Forces `parallel: 1` for production-state tests.
- Uses bounded apply, assert, exec, delete, and cleanup timeouts.
- Passes an explicit existing namespace for read-only production tests.
- Preserves the primary test exit status while recording cleanup and recovery
  outcomes separately.

### Destructive guards

Resilience protection is defense in depth:

1. The `just test resilience ...` recipe validates the exact
   `CLUSTER_CHAOS_CONFIRM` token.
2. The scenario's first operation invokes the same guard before any mutation.
3. Node actions require an explicit discovered node, verify workload placement,
   and derive valid node names/control-plane membership from repository or live
   state rather than examples such as `nuc-02`.
4. Reboot/drain scenarios verify another eligible Ready node and control-plane
   quorum before proceeding.
5. Cleanup contains the exact recovery operation, such as uncordon or VPN
   restoration, and reports failure separately.

The foundation implements token parsing and dispatch refusal. Action-specific
quorum and recovery checks are implemented with their corresponding scenario,
not as untested generic stubs.

### Diagnostics

Use Chainsaw `catch` handlers to collect transient state before cleanup wherever
possible: pod logs, previous logs, events, describes, and selected resources.
The runner performs a best-effort fallback collection after Chainsaw returns.

Diagnostics are allowlist-based:

- Never collect Kubernetes Secret bodies, decrypted SOPS files, process
  environments, control API keys, credentials, or complete Git diffs.
- Dirty-worktree metadata is a boolean/status summary only.
- Pod YAML may include Secret references but not dereferenced values.
- Probe and log collectors redact known sensitive fields before writing.
- Collection failure cannot replace the primary assertion result.

## Phase 4 — Evidence and results

Each invocation creates one collision-resistant run directory:

```text
.test-results/<UTC timestamp>-<short Git SHA>-<run suffix>/
├── summary.json
├── environment.json
├── junit.xml
├── logs/
├── manifests/
└── diagnostics/
```

The runner, not the Justfile, creates the run identifier. Using wall-clock time
for a live-run identity is expected and does not make the scenario itself
non-deterministic.

- Chainsaw runs once with `JUNIT-STEP` reporting and the wrapper normalizes its
  emitted report name to `junit.xml`.
- `environment.json` records start/end time, Git revision, dirty boolean, pinned
  tool versions, cluster versions when available, tier, target, an explicitly
  selected scenario when present, namespace, node, Pod UID, and confirmation
  token *type* only.
- `summary.json` records the primary status plus explicit safety, infrastructure,
  assertion, external-dependency, cleanup, and recovery fields.
- A public-IP provider outage is an external-dependency or infrastructure
  failure, never a passing leak test.

Failure classification must be backed by runner/probe output or parsed Chainsaw
operations. The foundation must not claim detailed classification merely because
all failures return nonzero.

## Phase 5 — Public commands, CI, and proof test

`tests/mod.just` contains thin wrappers with non-redundant names:

```text
validate                       # offline schema + shell validation
smoke target scenario=""       # operator-only, read-only
e2e target                     # operator-only, state-changing functional tests
resilience target              # operator-only, disruptive and token-guarded
diagnostics target             # operator-only, read-only collection
```

Operator examples:

```text
mise exec -- just test smoke cluster
mise exec -- just test smoke cluster diagnostics-self-test
mise exec -- just test e2e media
mise exec -- just test resilience qbittorrent-vpn-disconnect
mise exec -- just test diagnostics media
```

Add only `just test validate` to the root `ci` recipe; operators and CI invoke
that root recipe as `mise exec -- just ci`. No live tier enters hosted CI.

The proof test lives at
`tests/chainsaw/smoke/cluster/flux-ready/chainsaw-test.yaml` and:

- Sets `spec.namespace: flux-system` so Chainsaw does not create an ephemeral
  namespace.
- Sets concurrency off and performs no create/apply/patch/update/delete/script
  mutation.
- Asserts the expected Flux Kustomization has `Ready=True`.
- Uses bounded assertion timeouts.
- Produces the normal JUnit, summary, and environment artifacts.

This proves the harness and evidence path. It does not prove qBittorrent, VPN,
DNS, storage, gateway, or recovery behavior.

A separate opt-in diagnostics self-test is excluded from normal smoke selection.
It deliberately fails a read-only assertion so implementation verification can
prove that `catch` diagnostics are captured, the runner retains the primary
failure, and artifacts do not expose secrets.

## Required follow-up sequence for robust E2E

Foundation work is followed by separate, reviewable changes:

1. qBittorrent/Gluetun read-only smoke and forwarded-port agreement.
2. A unit-tested leak sentinel whose execution location is inside or observably
   tied to the qBittorrent network namespace.
3. Active DNS-isolation tests; `/etc/resolv.conf` inspection alone is not
   sufficient evidence.
4. Controlled VPN-stop/recovery with continuous transition evidence and forced
   cleanup-failure testing.
5. Pod recreation including startup-gating and persistence checks.
6. A realistic unexpected Gluetun failure mechanism. If it requires node/CRI
   access, add a separately guarded recipe rather than mislabeling a controlled
   API stop as a crash.
7. Node drain and Talos reboot with quorum, volume, SMB, and recovery evidence.
8. Controlled functional download and complete Servarr workflow.
9. Reusable Flux, Gateway API, DNS, Cilium, Longhorn, SMB, and cluster suites.
10. Periodic conformance testing where appropriate.

Only after the replacement scenarios pass repeatedly, exercise intentional
failure/cleanup paths, and retain sufficient artifacts may
`qbittorrent-killswitch-verify` be retired.

## Explicitly deferred from the foundation

- The Python/`uv` leak sentinel implementation.
- VPN interruption, sidecar failure, Pod recovery, drain, and reboot scenarios.
- Functional downloads and full Servarr workflow.
- Sonobuoy/conformance and any chaos-controller installation.
- Scheduled in-cluster tests.
- Broad CI access to the live cluster.
- Retirement of existing verification recipes before proven parity.

Gatus and the `PrometheusRule` remain the production continuous-monitoring layer;
the test framework supplements rather than replaces them.

## Files touched by the foundation

- New: `scripts/lib/common.sh`, `scripts/validate/*.sh`,
  `scripts/verify/*.sh`, `scripts/test/**`, `tests/mod.just`,
  `tests/README.md`, `tests/policy/**`, `tests/config/chainsaw.yaml`, and
  `tests/chainsaw/smoke/cluster/flux-ready/chainsaw-test.yaml`, plus the opt-in
  diagnostics self-test fixture.
- Edited: `.mise.toml`, `mise.lock`, `.gitignore`, `.justfile`,
  `kubernetes/mod.just`, `.just/repository.just`, `.pre-commit-config.yaml` when
  used for pinned schema validation, and documentation affected by command names.
- `.github/workflows/ci.yml` should remain unchanged if it continues to invoke
  only `mise exec -- just ci`.
- No `*.sops.yaml` file is decrypted or rewritten.

## Verification and completion criteria

Foundation is complete when:

1. The work is on a feature branch and the final diff is scoped and reviewed.
2. Mechanical validator extraction preserves behavior, followed by separately
   reviewed Conftest policy with native positive and negative Rego tests.
3. Extracted live verification wrappers remain guarded; operator-only parity
   checks are run or explicitly reported as skipped.
4. A clean workstation installs Conftest, Chainsaw, ShellCheck, and any
   conditionally required schema validator from pinned configuration and lock
   data.
5. `mise exec -- just test validate` validates every Chainsaw test/config file
   through confirmed cluster-free `chainsaw lint`, enforces the Conftest smoke
   safety policy, exercises result/confirmation regressions, and passes
   ShellCheck.
6. `mise exec -- just --list` exposes `just test validate|smoke|e2e|resilience`
   without redundant `test-test-*` naming.
7. `mise exec -- just ci` passes with no kubeconfig, age key, cluster, or DNS
   dependency beyond existing public chart/schema downloads.
8. An operator run of `mise exec -- just test smoke cluster` performs no
   Kubernetes mutation, passes against `flux-system`, and writes populated JUnit,
   summary, environment, and diagnostic artifacts; an optional third positional
   selects a registered scenario without changing the target axis.
9. A deliberately failing proof assertion demonstrates diagnostic capture and
   accurate primary-versus-diagnostic status without exposing secrets.
10. `.test-results/` is ignored, concurrent state-changing runs are refused, and
    no artifact contains secret values.

All commands use the pinned toolchain through `mise exec -- just ...`.

Completion of this foundation authorizes the workload scenario sequence; it does
not by itself satisfy the repository's robust E2E or VPN leak-proofing goal.
