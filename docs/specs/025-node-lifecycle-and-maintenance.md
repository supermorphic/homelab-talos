# Node Lifecycle and Maintenance

## Purpose

Define the operational lifecycle for disrupting one established node in the three-node
Talos, Kubernetes, etcd, Cilium, and Longhorn cluster. The design covers routine reboot,
planned physical maintenance, recovery acceptance, and a controlled abrupt electrical
power-loss test.

This specification supports
[GitHub issue 346](https://github.com/supermorphic/homelab-talos/issues/346). It applies
the command profiles and safeguards established by
[Repository Command Lifecycle](021-repository-command-lifecycle.md) to the platform in
[Talos and Flux Platform](010-talos-flux-platform.md). Current repository policy, executable source, pinned versions, and operational
documentation remain authoritative. Lifecycle execution moved to `homelab-playbook` in
2026. This specification remains the Talos repository record for the shared containment
protocol and the local observation and recovery-verification boundary. The playbook
repository's specification 011 is authoritative for the migrated action implementation.

## Scope

This design introduced:

- an established-node command domain for reboot, Longhorn volume resizing, and planned
  maintenance;
- an established-cluster observation domain for aggregate status and verification;
- a persistent Node-based containment state and a transient shared disruption Lease;
- a playbook-owned Kubernetes and Longhorn drain transaction;
- a common recovery-acceptance path;
- a controlled abrupt electrical power-loss resilience test; and
- the missing requested-member postcondition for exceptional etcd join retry.

This design does not:

- redesign the repository-wide command taxonomy;
- automate physical maintenance or electrical power control;
- broaden scoped agent credentials to permit node mutation;
- treat Longhorn replicas as backups;
- add a lifecycle controller, custom resource, or transaction journal;
- introduce a normal force-reboot command;
- make arbitrary application health part of aggregate cluster verification; or
- independently upgrade Talos, Kubernetes, Cilium, or Longhorn.

## Previous state and problem

The former `bootstrap reboot <node>` validated Kubernetes and etcd, required an exact
confirmation, immediately asked Talos to reboot the target, waited for its return, and
checked Secure Boot, TPM-backed volumes, etcd, and foundation health. It neither cordoned
nor drained the target. Workloads remained assigned when the node disappeared.

That behavior is useful evidence for an unprepared node disappearance, but it is not the
right routine lifecycle for an established node. It also cannot intentionally leave a
node safely powered off for physical work.

Several established-state commands were under `bootstrap`:

```text
bootstrap status [node]
bootstrap verify
bootstrap reboot <node>
bootstrap resize-longhorn <node>
```

The former public `bootstrap verify` was additionally a pre-Cilium bootstrap gate. It
expects Kubernetes Nodes to remain `NotReady` and performs a bounded ignored-kubeconfig
handoff. That behavior cannot become an established-cluster verifier through a blind
rename.

## Design principles

The lifecycle follows these rules:

1. Only one node can be intentionally unavailable or transitioning at a time.
2. A Lease represents transient ownership of an executing disruptive transaction.
3. A Node annotation plus cordon represents persistent lifecycle and containment state.
4. A safety-critical live condition is repeated immediately before consequential
   mutation.
5. Kubernetes eviction, PDBs, Longhorn safeguards, and etcd quorum checks are never
   bypassed merely to finish an operation.
6. A returned node is not schedulable until recovery has been explicitly accepted.
7. Recovery restores only state that the lifecycle transaction still demonstrably owns.
8. Failure after disruption is recovery pending or unresolved incident state, never an
   implied rollback.
9. Graceful routine lifecycle and intentionally unprepared resilience testing remain
   separate public operations.
10. Public commands own complete transaction semantics without naively chaining each
    other.

## Public command surface

Established-node maintenance, reboot, and attended abrupt-loss execution is owned by
`homelab-playbook`:

| Command | Profile | Confirmation |
| --- | --- | --- |
| `mise run playbook -- talos maintenance-check production -e @/absolute/private/request.json --check` | Read-only lifecycle check | None |
| `mise run playbook -- talos maintenance-enter production -e @/absolute/private/request.json` | Planned disruption | `talos_confirmation: enter:<node>:<ip>` in the private request |
| `mise run playbook -- talos maintenance-exit production -e @/absolute/private/request.json` | Recovery acceptance | `talos_confirmation: accept:<node>:<kind>` in the private request |
| `mise run playbook -- talos reboot production -e @/absolute/private/request.json` | Planned short disruption | `talos_confirmation: reboot:<node>:<ip>` in the private request |
| `mise run playbook -- talos abrupt-loss-test production -e @/absolute/private/request.json` | Controlled unprepared failure | Target-bound `talos_confirmation` and `talos_test_confirmation: chaos:node-abrupt-loss` in the private request |

This repository retains these related commands:

| Command | Profile | Confirmation |
| --- | --- | --- |
| `mise exec -- just node resize-longhorn <node>` | Destructive Talos volume operation | `TALOS_RESIZE_LONGHORN_CONFIRM='resize-longhorn:<node>:<ip>'` |
| `mise exec -- just cluster status [node]` | Read-only diagnostic view | None |
| `mise exec -- just cluster verify` | Read-only established-platform acceptance | None |

The playbook action resolves its source revision and target from its request. It uses this
repository's fixed `just kube recovery-verify REQUEST_FILE` interface for read-only
baseline and recovery acceptance. No deprecated local lifecycle aliases remain.

## Lifecycle state model

### Transient ownership

The existing renewable Lease implementation becomes the generalized disruption lock.
The same Lease identity is used by node lifecycle, qualifying topology-changing
operations, and existing mutating test orchestration:

```text
flux-system/homelab-test-run-lock
```

The resource name is historical, but retaining its identity prevents old and new
repository workflows from mistakenly using separate locks. The implementation moves
from its test-specific library location to a shared library without changing the proven
acquire, renew, verify-holder, and release behavior.

The Lease protects only an active transaction. It is acquired and renewed by:

- playbook `talos reboot`;
- playbook `talos maintenance-enter`;
- playbook `talos maintenance-exit`;
- `node resize-longhorn`;
- playbook `talos abrupt-loss-test`;
- `bootstrap retry-join`; and
- existing mutating test scenarios or campaigns whose current contract already requires
  the shared lock.

Read-only verification does not acquire the Lease. Unrelated mutations do not join the
lock without a concrete topology or stability requirement.

Lease expiry never clears persistent Node state. Loss of Lease ownership stops further
mutation, and a process never releases another holder's Lease. Holder ownership is
rechecked immediately before each consequential mutation.

### Persistent containment

One annotation on the Kubernetes Node carries the minimum durable recovery record:

```text
homelab.supermorphic.com/node-lifecycle
```

Routine reboot and abrupt loss use small records:

```json
{"schemaVersion":1,"kind":"reboot"}
```

```json
{"schemaVersion":1,"kind":"abrupt-loss"}
```

Maintenance also records the Longhorn values observed before entry and the values the
lifecycle intends to own during maintenance:

```json
{
  "schemaVersion": 1,
  "kind": "maintenance",
  "longhorn": {
    "allowScheduling": {
      "before": true,
      "during": false
    },
    "evictionRequested": {
      "before": false,
      "during": true
    }
  }
}
```

The annotation does not contain step flags, timestamps, hardware identifiers, or a
general transaction journal. Unknown schema versions, malformed records, unsupported
kinds, and conflicting live state fail closed.

The Node annotation and Kubernetes cordon are written in one optimistic-concurrency
patch and read back before any dependent mutation. Final annotation removal and
uncordon are likewise one Node-object patch. Neither patch makes changes to separate
Longhorn objects atomic; those changes are explicitly ordered and verified.

### States

| State | Durable and live condition |
| --- | --- |
| Established | Node `Ready`, schedulable, and without lifecycle annotation |
| Transitioning | Shared Lease held while a command checks, drains, disrupts, or recovers |
| Maintenance | Node cordoned with `kind=maintenance`; it may remain offline indefinitely |
| Recovery pending | Node cordoned with `kind=reboot` or `kind=abrupt-loss`; acceptance is incomplete |
| Unresolved incident | Disruption occurred but containment could not be persisted or live state conflicts with the record |

Transitioning is not a durable state on its own. Maintenance and recovery-pending state
survive command exit without a live Lease.

An unannotated cordon or unexpected `NotReady` Node blocks another disruption. It is not
silently adopted or uncordoned. Explicit adoption or incident recovery requires exact
operator intent and must not be invented as automatic cleanup. No separate
`maintenance-cancel`, `reboot-recover`, or `abrupt-loss-recover` command is introduced
without evidence that the common exit path cannot handle supported records safely.

## Admission and one-node invariant

`maintenance-check` provides a read-only advisory result. Every mutating command
acquires the shared Lease and repeats the applicable checks before mutation.

An established-node disruption is admitted only when:

- the exact target resolves to the expected Kubernetes and Talos identity;
- the target is established: its Talos API is healthy and its Kubernetes Node is
  `Ready`, schedulable, and without a lifecycle annotation;
- the exact expected three Kubernetes Nodes are present;
- no other node carries a lifecycle annotation;
- no other node is cordoned or `NotReady`;
- all non-target nodes can carry the control plane and expected failover demand;
- all expected etcd members are healthy and reachable with no relevant alarms;
- Cilium is healthy on the target and survivors;
- affected workloads have eligible surviving placement;
- PDB, unmanaged-pod, local-data, and drain conditions are understood;
- Longhorn can tolerate loss of the target under the operation-specific contract; and
- the caller still owns the shared Lease.

Remaining-node capacity is concrete admission evidence. Each survivor must report
`Ready=True`, `MemoryPressure=False`, `DiskPressure=False`, `PIDPressure=False`, and no
active `NetworkUnavailable` condition. For workloads expected to fail over, preflight
checks eligible surviving placement after node selectors, affinity, taints, topology
spread, and extended-resource requirements. It compares requested CPU, memory,
ephemeral storage, pod slots, and extended resources with surviving allocatable capacity
minus requests from existing non-terminal pods. Required pod affinity, required pod
anti-affinity, and hard topology-spread constraints use the current survivor domains and
the placements selected for other displaced pods. Selector forms that need namespace or
scheduler state unavailable to this check fail closed. This conservative calculation
does not replace actual scheduler recovery as the post-disruption oracle.
Longhorn checks provide the separate storage-placement evidence.

While one node has persistent lifecycle state, only `maintenance-exit` for that same
target can begin. Another reboot, maintenance entry, resize, join retry, or disruptive
test is refused even when the Lease is currently free. `maintenance-exit` still acquires
the Lease because recovery changes topology and ends containment.

Every Lease participant that can make a node or required workload unavailable must run
this persistent-state admission check after acquiring the Lease and before mutation.
Acquiring the Lease alone is insufficient because a successful `maintenance-enter`
releases it while the node remains deliberately unavailable.

## Kubernetes drain contract

The repository, not Talos client-side drain behavior, owns Kubernetes evacuation. The
explicit sequence is:

```text
inventory target workloads
-> reject unmanaged pods
-> report local ephemeral data
-> use Kubernetes eviction
-> respect every PDB
-> ignore but do not delete DaemonSets
-> wait for source workloads to terminate
-> prove expected replacement workloads are Ready on surviving nodes
-> prove required storage detached, reattached, and mounted
-> prove no drainable workload remains
```

The drain does not use `--disable-eviction`, `--force`, a PDB bypass, or direct deletion
as fallback. It permits normal deletion of declared `emptyDir` data after reporting the
inventory because that storage is node-local and cannot survive reboot or maintenance.
A workload that relies on `emptyDir` for durable state violates its deployment contract.

The observational preflight confirms that Kubernetes core `/api/v1` discovery advertises
`pods/eviction`. It uses `kubectl drain --dry-run=client`, so scoped credentials can
exercise pod discovery and drain classification without node-patch or eviction authority.
The operator-run transaction repeats API discovery and performs the real eviction only
after it has persisted lifecycle containment.

For each controller-owned workload that preflight classifies as expected to continue
during the target's absence, drain completion requires an actual replacement Pod on an
eligible surviving node and its Kubernetes readiness condition. A PVC-backed workload
must retain the same PVC and PV identity, complete required detach and attach operations,
and mount its storage before it is accepted. This is transaction-specific verification
of affected workloads, not application health added to the general cluster contract.

Static mirror Pods identified by `kubernetes.io/config.mirror` do not require a
surviving replacement, consistently with drain inventory and capacity checks.
Their control-plane availability is covered by the Talos, etcd, and foundation gates.
Pods already in `Succeeded` or `Failed` phase at inventory capture do not require
replacement. An active Job can instead satisfy recovery with its `Complete=True`
condition, provided the live Job UID matches the captured controller UID. Otherwise
its Ready survivor replacement is required. Longhorn-managed InstanceManager Pods
in `longhorn-system` are node-local infrastructure: eviction remains subject to their
PDB, and Longhorn evacuation/convergence provides their acceptance evidence.
Replacement observations retry for up to 60 attempts, five seconds apart, to allow
controllers and readiness probes to converge after drain. Exhaustion preserves
containment and prevents shutdown.

For Plex, these generic checks use its existing `/identity` readiness probe, require the
same Longhorn-backed configuration volume to attach on the landing node, and require the
SMB media volume to mount. Its 120-second termination grace period allows an orderly
SQLite shutdown. Its `emptyDir` transcode data is reported and discarded, so an active
stream or transcode can be interrupted even though the workload transition is graceful.
The lifecycle does not create a Plex persistence marker or duplicate the complete
`plex-cross-node-reschedule` resilience test.

A blocked or timed-out drain stops before reboot or shutdown. The node remains annotated
and cordoned for recovery through `maintenance-exit`.

The pinned Talos 1.13.7 CLI has an optional `reboot --drain` path. Its implementation
cordons and drains before reboot, then uses deferred cleanup to uncordon even when a
later stage fails. That behavior conflicts with persistent containment, so `talos reboot`
does not pass `--drain`.

Talos 1.13.7 `shutdown` behaves differently: it performs its own cordon and drain unless
`--force` is supplied. In this specific command, `--force` suppresses that duplicate
Kubernetes drain but still runs the normal Talos machine sequence that stops pods,
services, and filesystems before shutdown. `maintenance-enter` may use
`talosctl shutdown --force` only after the repository-owned drain and Longhorn evacuation
have succeeded and the final safety checks still pass. This use is not a forced
Kubernetes eviction or a bypass of a failed drain.

## Longhorn contracts

### Reboot

Routine reboot performs workload evacuation and storage-safety validation but does not
fully evacuate replicas. It does not disable Longhorn replica scheduling or request
replica eviction.

For every affected volume, preflight requires:

- no faulted volume state;
- a healthy usable replica away from the target;
- no rebuild, migration, or replica condition that makes the short loss unsafe;
- a Longhorn Node Drain Policy that protects the last healthy replica without
  automatically evacuating all target replicas merely because the Node is cordoned;
- successful Kubernetes eviction without bypassing Longhorn PDB protection; and
- safe detachment from the target or attachment on the rescheduled workload node.

Longhorn reports a detached volume with `robustness=unknown`. Preflight accepts that
combination only when every desired non-failed replica exists and at least one is stored
away from the target. Attached volumes must report `healthy`.

Reusable target replicas remain in place for Longhorn's short-outage recovery behavior.
Post-reboot acceptance verifies their reuse or safe convergence.

### Maintenance entry

Maintenance can leave a node absent for an arbitrary duration. After persisting and
verifying the lifecycle record and cordon, the command applies the Longhorn `during`
values with optimistic concurrency, verifies them, drains workloads, and completes full
replica evacuation.

Longhorn also marks a cordoned Kubernetes Node unschedulable in its calculated
`Schedulable` condition when `DisableSchedulingOnCordonedNode` is enabled. That status
effect is distinct from the lifecycle-owned Longhorn Node spec fields recorded here.
The explicit `allowScheduling=false` record remains necessary for durable maintenance
intent and can be restored while the Kubernetes Node is still cordoned; effective
scheduling resumes only after the final uncordon.

Success requires:

- new replicas cannot be scheduled to the target;
- replica eviction is requested;
- every affected volume reaches its configured healthy replica count on the two
  remaining nodes; and
- zero Longhorn volume replicas remain scheduled on or stored by the target, including
  replicas for detached volumes.

Only then may Talos shut the node down. The repository uses a Talos shutdown path that
does not perform a second Kubernetes drain; pinned Talos behavior must still provide its
normal service, pod, and filesystem shutdown after the repository-owned evacuation.

### Compare and restore

`maintenance-exit` restores a recorded field only after comparing current Longhorn state:

```text
current == during
  -> lifecycle still owns the setting
  -> restore before

current == before
  -> already restored or during was never applied
  -> no-op

current != during and current != before
  -> conflicting external or unexpected change
  -> do not overwrite
  -> preserve containment
```

When `before` equals `during`, the lifecycle did not own a change. Recovery requires the
value to remain unchanged and does not rewrite it.

After containment, maintenance entry reads the Longhorn Node again and compares the
owned settings with the recorded before values. It uses this fresh resource version
for the atomic update of both settings. Status updates between record construction
and containment do not invalidate unchanged settings; conflicts during the update
still fail closed. Recovery also uses the current resource version and reads back
the result before final Node acceptance.

Evacuation and recovery accept attached healthy volumes and detached unknown volumes
only with the configured non-failed replica count. Evacuation additionally requires
no remaining non-failed replica on the target. Command entrypoints run in subshells
so failure cleanup retains its local Lease and temporary-file state until EXIT.

The required recovery order is:

```text
acquire Lease
-> verify lifecycle annotation and cordon
-> wait for target control-plane and storage services
-> compare Longhorn current state with before/during
-> restore only lifecycle-owned values
-> read back and prove restoration
-> wait for required Longhorn convergence
-> complete platform acceptance
-> repeat critical checks and verify Lease ownership
-> atomically remove lifecycle annotation and uncordon
```

If Longhorn restoration succeeds but later acceptance fails, a repeated
`maintenance-exit` observes `current == before` and continues safely.

## Operation state machines

### Maintenance check

```text
resolve exact target
-> inspect Lease and persistent lifecycle state
-> evaluate target, Kubernetes, etcd, Cilium, workloads, PDBs, capacity, and Longhorn
-> report safe or actionable blockers
-> perform no mutation
```

The result can become stale and is never authority for later mutation.

### Maintenance enter

```text
acquire Lease
-> repeat admission checks
-> exact target-bound confirmation
-> read current Node and Longhorn state
-> construct minimal before/during record
-> atomically annotate and cordon with optimistic concurrency
-> read back and verify containment
-> apply and verify Longhorn during values with optimistic concurrency
-> gracefully drain workloads
-> fully evacuate required Longhorn replicas
-> repeat disruption safety checks
-> request Talos shutdown without a second client-side drain
-> verify the node is offline and remains cordoned
-> release Lease
```

Successful entry deliberately stops with the node unavailable, cordoned, annotated, and
safe for arbitrary-duration physical maintenance. It must not succeed merely because a
node disappeared and returned automatically.

### Routine reboot

```text
acquire Lease
-> repeat admission checks
-> exact target-bound confirmation
-> atomically annotate reboot and cordon
-> verify containment
-> gracefully drain workloads
-> verify short-absence Longhorn safety without replica evacuation
-> repeat critical safety checks and Lease ownership
-> request Talos reboot without Talos client-side drain
-> observe disappearance and return
-> recover while still cordoned
-> complete acceptance
-> atomically remove annotation and uncordon
-> release Lease
```

Failure after annotation leaves the node contained. A reboot that does not complete
acceptance is resumed with `maintenance-exit`, not a new reboot-specific command.

### Maintenance exit and common recovery

The operator physically starts a maintained node before invoking `maintenance-exit`.
The command also accepts supported interrupted reboot and abrupt-loss records.

```text
acquire Lease
-> validate exact target and persisted kind
-> require accept:<node>:<kind>
-> wait for Talos and Kubernetes return
-> restore lifecycle-owned Longhorn state when recorded
-> complete common and kind-specific acceptance
-> repeat critical checks and Lease ownership
-> atomically remove annotation and uncordon
-> verify the Node object
-> release Lease
```

The standalone confirmation is required because maintenance exit is a new transaction,
possibly hours or days after entry. The original entry confirmation is stale. Successful
reboot and abrupt-loss commands need no second confirmation for their built-in exit
because the original command and Lease continuously own those bounded transactions.

### Abrupt electrical power-loss resilience test

This test is not a normal node lifecycle command. It deliberately proves behavior after
unprepared loss and therefore lives only under `test resilience`.

The operator must remove and later restore electrical input to the selected NUC. A
normal power-button shutdown does not satisfy the procedure. Restoring electrical power
must cause firmware to start the NUC automatically.

The repository has no managed power telemetry. It cannot independently prove the
electrical state, so it records the operator procedure and proves the resulting loss
through distinct observations:

```text
Talos API unreachable
AND Kubernetes Node NotReady or Unknown
AND target etcd member unreachable
AND remaining etcd members retain quorum
```

The default sequence is:

```text
require scenario confirmation
-> acquire Lease and pass lifecycle admission
-> require exact target confirmation
-> establish healthy baseline
-> start continuous probes
-> request electrical disconnection
-> observe genuine unprepared multi-plane loss
-> atomically annotate abrupt-loss and cordon the already-offline Node
-> passively observe autonomous cluster recovery
-> record workload, storage, and service behavior
-> request electrical restoration
-> recover while cordoned
-> require full platform and Longhorn convergence
-> atomically remove annotation and uncordon
-> release Lease
```

Nothing annotates, cordons, drains, or otherwise prepares the target before electrical
removal. The post-loss ordinary cordon prevents new scheduling when the node returns but
does not force-delete pods or detach volumes, so passive observation remains valid.

The default test does not add `node.kubernetes.io/out-of-service`. Kubernetes documents
that taint as a non-graceful-shutdown intervention that force-deletes pods and triggers
immediate volume detach. Applying it early would hide the autonomous behavior the test
is intended to measure. It must be used only after independently confirming the node is
powered off and removed after the node has recovered. A future extended scenario or
explicit incident procedure requires separate design, authorization, owned-taint
cleanup, and evidence.

#### Baseline

Before power removal, the test records:

- exact target identity and three-node health;
- etcd membership, leader, endpoint health, and alarms;
- remaining-node capacity and workload placement eligibility;
- non-DaemonSet workloads currently hosted by the target;
- affected PVCs, logical volume ownership, and off-target healthy replicas;
- Cilium and foundation health; and
- external API, DNS, and trusted HTTPS probe baselines.

It refuses the test when an affected durable volume has no healthy replica away from the
target.

#### Passive degraded-state evidence

While power remains disconnected, the test records and evaluates:

| Layer | Evidence |
| --- | --- |
| Control plane | Exactly two surviving Nodes `Ready`, healthy two-member etcd quorum, usable Kubernetes API |
| Network | Cilium healthy on survivors; API/VIP, DNS, and trusted HTTPS continuity samples |
| Workloads | Autonomous behavior and recovery time for eligible controller-owned workloads; stuck stateful or singleton workloads remain visible |
| Storage | PVC identity preservation, surviving healthy replicas, volume usability where expected, robustness, replenishment, and rebuild activity |

The default test does not wait for every affected volume to regain full configured
replica count while the node remains absent. That would turn every run into an extended
storage-reconstruction test. Full replica reconstruction during sustained absence is a
separate future resilience scenario. The default requires complete Longhorn convergence
after power restoration.

External core probes begin before power removal and continue through recovery. The
repository policy defaults are:

| Setting | Default |
| --- | ---: |
| Probe cadence | 5 seconds |
| Core-path no-success limit | 60 seconds |
| Power-loss detection | 3 minutes |
| Passive observation | 10 minutes |
| Electrical-restoration wait | 30 minutes |
| Full recovery acceptance | 30 minutes |

The 60-second limit is a repository SLO, not a Kubernetes guarantee. Overrides are
bounded, validated, and printed before disruption. Singleton workload failover can take
longer and is measured separately rather than described as uninterrupted service.

If passive observation fails, the test still requests electrical restoration and
attempts recovery. It reports the primary assertion, containment, cleanup, and recovery
independently. A valid result can therefore show a failed resilience assertion with
successful node recovery.

## Recovery acceptance

Return and acceptance are different states:

```text
returned
  = Talos and Kubernetes can see the node

accepted
  = required platform and storage invariants pass
```

Common acceptance requires:

- the exact Talos machine identity;
- expected boot, Secure Boot, TPM-backed disk unlock, and Talos volume state;
- Kubernetes Node `Ready` while still cordoned with the expected annotation;
- exact three-member etcd health, quorum, leader, and absence of alarms;
- Cilium health on the returned node and restored cluster connectivity;
- Longhorn node, manager, engine, replica, attachment, and affected-volume convergence;
- recovery of workloads affected by the transaction; and
- core foundation DNS, Gateway, trusted HTTPS, and service dependencies.

`cluster verify` and lifecycle acceptance stay scoped to core platform health. They do
not make unrelated application health a cluster invariant. A lifecycle transaction may
verify the specific workloads it drained or observed without adding them to the general
cluster contract.

`talos reboot` additionally proves safe reuse or convergence of replicas retained for the
short outage. `maintenance-exit` restores recorded Longhorn state before storage
convergence. Abrupt-loss recovery requires both its separately recorded degraded-state
result and full three-node recovery.

Immediately before the final mutation, the command repeats critical health and storage
checks, verifies Lease ownership, and verifies that no competing lifecycle state has
appeared. It then atomically removes the annotation and clears `spec.unschedulable`, and
reads back the result. An ambiguous or failed final patch is unresolved recovery, not
assumed success.

## Failure semantics

Failure handling is based on whether lifecycle mutation or node disruption has actually
started:

- Failure before any node disruption or lifecycle mutation releases the Lease and
  leaves the node unchanged.
- Failure after annotation and cordon but before reboot or shutdown preserves containment
  unless an explicitly proven safe rollback succeeds.
- Drain failure prevents reboot and shutdown.
- Replica-evacuation failure prevents maintenance shutdown.
- Failure after reboot, shutdown, or physical power removal is recovery pending even if
  annotation or cordon could not be persisted. It is never reported as rollback.
- Failure to return leaves the node offline, cordoned, and annotated when those states
  can be persisted.
- Recovery-acceptance failure leaves an online node cordoned and annotated.
- Failure to persist containment after disruption reports unresolved lifecycle or
  incident state. Existing `NotReady` and cordon admission checks still block another
  node disruption until explicitly resolved.
- Conflicting Longhorn state is not overwritten and preserves Node containment.
- An unexpected unannotated `NotReady` or cordoned Node blocks new disruption and
  requires explicit adoption or separate incident recovery.
- No cleanup trap automatically uncordons a node whose recovery was not accepted.

If the active process stops after abrupt loss, the persisted annotation and cordon—or,
when that write failed, the observed `NotReady` state—provide the available containment
signal. If a target cannot be restored, it remains unavailable and blocks another
intentional node disruption. Repair or reinstall follows the existing disaster-recovery
boundary, after which `maintenance-exit` can accept a supported persisted lifecycle
record. Permanent replacement or etcd-member removal requires a separate reviewed plan.

## Established-cluster observation

### Cluster status

`cluster status [node]` is the semantic move of the current read-only Talos and etcd
diagnostic view. The optional target remains useful for focused service, discovery, and
recent-log inspection.

### Cluster verify

`cluster verify` is a new established-cluster aggregate, not the current pre-Cilium
implementation under a new name. It composes existing authoritative verifiers where
possible and remains limited to:

- the expected Kubernetes Nodes;
- etcd membership and health;
- Talos machine and volume health;
- Cilium;
- Longhorn; and
- foundation networking, DNS, Gateway, certificate, and trusted HTTPS dependencies.

It does not duplicate those checks into one large new script and does not include
arbitrary application health.

The current pre-Cilium behavior becomes a private bootstrap prerequisite invoked by the
Cilium bootstrap transaction. Its `NotReady` expectation and bounded kubeconfig handoff
remain bootstrap-specific and are not exposed as established-cluster acceptance.

## Related disruptive operations

### Longhorn volume resize

`node resize-longhorn` retains its existing destructive Talos-volume contract and exact
confirmation while moving to the established-node domain. It holds the shared
disruption Lease for its complete two-reboot transaction and refuses another active or
persistent node lifecycle condition.

The rename does not authorize a live resize merely to prove the new command name.

### Etcd join retry

`bootstrap retry-join` remains an exceptional bootstrap recovery command. It joins the
shared Lease because reboot and etcd membership convergence require exclusive topology.
If the Kubernetes API needed for Lease coordination is unavailable, it fails closed
rather than inventing another lock.

Success requires all of the following:

```text
requested member joined
AND exact expected etcd membership is healthy
AND no relevant etcd alarms remain
```

## Authority and credential boundary

The local `cluster status`, `cluster verify`, and recovery-verification commands remain
observational. The fixed recovery verifier requires explicit kubeconfig, talosconfig,
and context values in its validated request and uses only the prepared Helm cache bound
by the playbook adapter.

Mutating node lifecycle and abrupt-loss actions are operator-run in `homelab-playbook`.
That repository owns inventory selection, private request validation, credentials,
confirmation, PTY handling, and invocation of the pinned Talos lifecycle role. It copies
the selected clean Talos source revision into a private runtime directory before it calls
the fixed verifier. Permission failure never causes broader-credential fallback, RBAC
modification, or ad hoc privilege escalation.

Confirmation is an execution-intent and target-binding guard, not authorization.

## Implementation structure

`homelab-playbook` owns the lifecycle state machine, drain, Longhorn handling, Talos
operations, accepted recovery, and attended abrupt-loss controller. This repository owns
the fixed read-only recovery verifier and its prepared chart cache, plus the generic
Lease, disruption-admission, node-target, Longhorn-verification, resize, cluster
observation, Cilium, foundation, and bootstrap retry-join support used by local workflows.

The root Justfile retains `.just/node.just` only for `node resize-longhorn`. Lifecycle
commands no longer delegate to `scripts/node/` here. The shared Node annotation schema and
Lease name remain a cross-repository protocol so the verifier and retained disruptive
operations reject concurrent or malformed lifecycle state.

## Resilience-test allocation

The application-specific `plex-node-reboot` test remains retired. Its useful assertions
remain under `plex-cross-node-reschedule`: replacement readiness, unchanged PVC identity,
Longhorn attachment, persistence-marker survival, and SMB media remount.

The former local `node-abrupt-loss` catalog scenario is retired. Its complete attended
experiment and its offline regression coverage moved to the `homelab-playbook` `talos
abrupt-loss-test` action. It is not a Talos catalog suite or campaign member.

## Command migration

The migration removes the local maintenance, reboot, and abrupt-loss recipes,
controllers, lifecycle-only fixtures, catalog registration, dispatch, and publication
references in one cutover. It retains the shared protocol readers and unrelated generic
support named above. A Node with an existing lifecycle annotation must be recovered with
the matching playbook action; downgrading to an implementation that cannot interpret the
record remains unsafe.

## Validation

Cluster-independent validation is split across the two repositories. `homelab-playbook`
proves request validation, target resolution, confirmation, credentials, lifecycle state
transitions, ordered mutation, failure containment, PTY interaction, and the attended
abrupt-loss controller. This repository proves:

- the fixed prepare, baseline, and recovery verifier contract;
- fail-closed lifecycle annotation parsing and recovery gates;
- cache-only chart identity, version, and digest validation before target calls;
- the real Cilium, foundation, Flux, Talos, etcd, and Longhorn verification chain;
- generic Lease and disruption-admission behavior;
- retained Longhorn resize and bootstrap retry-join serialization;
- the local command, catalog, harness, impact, and publication inventories; and
- retained Plex reschedule coverage after the local abrupt-loss scenario retirement.

The canonical Talos pre-publication gate is `mise exec -- just test ci-publish`. Live
node disruption is outside CI and requires separate operator authorization in the
playbook repository.

## Live validation

Linked-worktree credentials cannot run disruptive validation. After merge and required
Flux reconciliation, operator-owned live validation increases disruption in this order:

1. Verify the updated scoped observer RBAC.
2. Run local `cluster status` and `cluster verify`, then playbook `talos
   maintenance-check` against each node.
3. Run one graceful playbook `talos reboot` transaction.
4. Run one playbook `talos maintenance-enter`, physical power-on, and `talos
   maintenance-exit` cycle.
5. Run playbook `talos abrupt-loss-test` last with actual electrical disconnection and
   restoration.

All three nodes must be fully established before advancing to the next disruptive step.
`node resize-longhorn` is not executed merely to validate its rename.

## Alternatives rejected

### Talos-owned client drain

Talos exposes client-side drain options, but that path owns cordon and uncordon behavior
without the playbook's independent PDB, workload, Longhorn, persistent containment,
and recovery-acceptance contract. The playbook therefore owns drain explicitly and
uses Talos only for the machine reboot or shutdown stage.

### Full replica evacuation for every reboot

This would convert a short routine disruption into expensive storage reconstruction and
discard reusable replicas. Routine reboot instead proves a safe surviving replica and
retains target replicas. Arbitrary-duration maintenance performs complete evacuation.

### Full replica reconstruction during every abrupt-loss test

Waiting through the replenishment interval and rebuilding every affected replica before
power restoration would test extended storage reconstruction, not only abrupt node loss.
The default records degraded behavior and requires final convergence after restoration.

### Immediate out-of-service intervention

Adding the Kubernetes out-of-service taint immediately would force pod deletion and
volume detach, hiding autonomous failure behavior. The default test stays passive.

### Separate persistent lifecycle resource

A ConfigMap or custom resource would create synchronization and ownership states without
a current need. The versioned Node annotation holds the minimum recovery record.

### Separate recovery commands

`reboot-recover`, `abrupt-loss-recover`, and `maintenance-cancel` would duplicate the
same acceptance and uncordon boundary. `maintenance-exit` handles supported persistent
kinds unless implementation evidence proves it cannot.

### Compatibility aliases

Aliases would preserve parallel terminology and weaken the command-lifecycle migration
rule. Every repository-owned caller moves atomically.

## Upstream basis

The design was checked against the versions pinned by this repository and the matching
upstream operational guidance:

- [Talos 1.13.7 reboot CLI source](https://github.com/siderolabs/talos/blob/v1.13.7/cmd/talosctl/cmd/talos/reboot.go)
  defines the optional client-side drain and deferred uncordon behavior.
- [Talos 1.13.7 shutdown CLI source](https://github.com/siderolabs/talos/blob/v1.13.7/cmd/talosctl/cmd/talos/shutdown.go)
  and its [machine shutdown sequence](https://github.com/siderolabs/talos/blob/v1.13.7/internal/app/machined/pkg/runtime/v1alpha1/v1alpha1_sequencer.go)
  define the narrow effect of `shutdown --force` and the remaining orderly stop phases.
- [Kubernetes drain](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_drain/)
  defines eviction, DaemonSet, unmanaged-pod, and local-data behavior.
- [Kubernetes non-graceful node shutdown](https://kubernetes.io/docs/concepts/cluster-administration/node-shutdown/)
  defines the powered-off prerequisite and effect of the out-of-service taint.
- [Longhorn 1.12.0 node maintenance](https://longhorn.io/docs/1.12.0/maintenance/maintenance/)
  defines cordon, drain policy, reusable-replica, and planned-evacuation behavior.

## Completion criteria

The initiative is complete when:

1. `homelab-playbook` owns maintenance check, maintenance enter, maintenance exit, reboot,
   and abrupt-loss execution through its registered `talos` actions.
2. The fixed Talos recovery verifier provides prepare, baseline, and recovery modes and
   performs no runtime chart fetch.
3. The shared Lease and persistent Node state enforce the one-node invariant across the
   playbook actions and retained Talos workflows.
4. This repository retains cluster observation, Longhorn resize, bootstrap retry-join,
   and generic protocol support without a runtime dependency on the retired lifecycle
   controller.
5. Plex-specific persistence coverage remains without `plex-node-reboot`.
6. The old abrupt-loss catalog scenario, lifecycle commands, implementation bodies,
   fixtures, and publication references are absent.
7. Both repositories' focused offline gates pass at the recorded cutover revisions.

## Consequences

Routine node operation becomes orderly and recoverable: the cluster proves it can lose
one node, drains workloads, contains the target, accepts its return, and only then makes
it schedulable. Planned maintenance can span an arbitrary physical-work interval without
holding an active Lease. Reboot remains efficient by preserving reusable replicas.

The combined repositories retain honest high-availability evidence. Abrupt electrical loss
is tested explicitly without graceful preparation, application-specific Plex coverage
stays with the Plex scenario, and passive behavior remains distinguishable from incident
intervention.

The design adds operational machinery and attended validation, but it avoids an
in-cluster controller, another persistent resource, a transaction journal, compatibility
aliases, and broader agent authority. The resulting lifecycle is explicit enough to
recover safely while remaining proportional to a three-node homelab cluster.
