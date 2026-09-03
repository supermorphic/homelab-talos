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
[Talos and Flux Platform](010-talos-flux-platform.md). Current repository policy,
executable source, pinned versions, and operational documentation remain authoritative.

## Scope

This design introduces:

- an established-node command domain for reboot, Longhorn volume resizing, and planned
  maintenance;
- an established-cluster observation domain for aggregate status and verification;
- a persistent Node-based containment state and a transient shared disruption Lease;
- a repository-owned Kubernetes and Longhorn drain transaction;
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

## Current state and problem

The current `bootstrap reboot <node>` validates Kubernetes and etcd, requires an exact
confirmation, immediately asks Talos to reboot the target, waits for its return, and
checks Secure Boot, TPM-backed volumes, etcd, and foundation health. It neither cordons
nor drains the target. Workloads remain assigned when the node disappears.

That behavior is useful evidence for an unprepared node disappearance, but it is not the
right routine lifecycle for an established node. It also cannot intentionally leave a
node safely powered off for physical work.

Several established-state commands currently remain under `bootstrap`:

```text
bootstrap status [node]
bootstrap verify
bootstrap reboot <node>
bootstrap resize-longhorn <node>
```

The current public `bootstrap verify` is additionally a pre-Cilium bootstrap gate. It
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

The approved surface is:

| Command | Profile | Confirmation |
| --- | --- | --- |
| `mise exec -- just node maintenance-check <node>` | Read-only lifecycle check | None |
| `mise exec -- just node maintenance-enter <node>` | Planned disruption | `NODE_MAINTENANCE_CONFIRM='enter:<node>:<ip>'` |
| `mise exec -- just node maintenance-exit <node>` | Recovery acceptance | `NODE_LIFECYCLE_CONFIRM='accept:<node>:<kind>'` |
| `mise exec -- just node reboot <node>` | Planned short disruption | `NODE_REBOOT_CONFIRM='reboot:<node>:<ip>'` |
| `mise exec -- just node resize-longhorn <node>` | Destructive Talos volume operation | Existing `TALOS_RESIZE_LONGHORN_CONFIRM='resize-longhorn:<node>:<ip>'` |
| `mise exec -- just cluster status [node]` | Read-only diagnostic view | None |
| `mise exec -- just cluster verify` | Read-only established-platform acceptance | None |
| `mise exec -- just test resilience node-abrupt-loss <node>` | Controlled unprepared failure | `CLUSTER_CHAOS_CONFIRM='chaos:node-abrupt-loss'` and `NODE_ABRUPT_LOSS_CONFIRM='remove-power:<node>:<ip>'` |

`NODE_REBOOT_CONFIRM` replaces `TALOS_REBOOT_CONFIRM` because the new operation owns a
Kubernetes, Longhorn, and Talos lifecycle rather than only a Talos reboot.

The recovery token follows the established repository grammar of an action prefix plus
target context. Its lifecycle kind is read from persisted state, so a confirmation for
one recovery state cannot accept a different state.

The following semantic moves are atomic and leave no aliases:

```text
bootstrap reboot <node>          -> node reboot <node>
bootstrap resize-longhorn <node> -> node resize-longhorn <node>
bootstrap status [node]          -> cluster status [node]
bootstrap verify                 -> cluster verify
```

`bootstrap retry-join <node>` remains exceptional bootstrap recovery. A command is not
moved only because it accepts a node argument.

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

- `node reboot`;
- `node maintenance-enter`;
- `node maintenance-exit`;
- `node resize-longhorn`;
- `test resilience node-abrupt-loss`;
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
checks eligible surviving placement after node selectors, affinity, taints, storage
topology, and extended-resource requirements. It compares requested CPU, memory,
ephemeral storage, pod slots, and extended resources with surviving allocatable capacity
minus requests from existing non-terminal pods. This conservative calculation does not
replace actual scheduler recovery as the post-disruption oracle.

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

For each controller-owned workload that preflight classifies as expected to continue
during the target's absence, drain completion requires an actual replacement Pod on an
eligible surviving node and its Kubernetes readiness condition. A PVC-backed workload
must retain the same PVC and PV identity, complete required detach and attach operations,
and mount its storage before it is accepted. This is transaction-specific verification
of affected workloads, not application health added to the general cluster contract.

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
later stage fails. That behavior conflicts with persistent containment, so `node reboot`
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

The entry-time Longhorn mutation uses the resource version read while constructing the
record. When both fields belong to the same Longhorn Node object, they change in one
optimistic-concurrency patch. Recovery uses the current resource version, reads back the
result, and waits for storage convergence before final Node acceptance.

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
acquire Lease
-> establish healthy baseline and start continuous probes
-> require scenario and exact target confirmations
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

`node reboot` additionally proves safe reuse or convergence of replicas retained for the
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

These observational commands remain usable with linked-worktree scoped credentials:

```text
node maintenance-check
cluster status
cluster verify
```

The observer receives only missing `get`, `list`, and `watch` access for:

- the shared Lease;
- Longhorn Replicas; and
- Longhorn Settings.

Existing read access covers the other required objects. Observer and diagnostic roles do
not receive create, update, patch, delete, eviction, exec, port-forward, shutdown, or
reboot authority.

Mutating node lifecycle and abrupt-loss commands are operator-run and refuse scoped
linked-worktree credentials before mutation. They require the authorized main-clone
Kubernetes and Talos credentials. Permission failure never causes broader-credential
fallback, RBAC modification, or ad hoc privilege escalation.

Confirmation is an execution-intent and target-binding guard, not authorization.

## Implementation structure

The root Justfile adds thin `node` and `cluster` modules. Public recipes delegate to a
shared Bash lifecycle controller under `scripts/node/`. The controller owns target
resolution, Lease handling, structured-state parsing, optimistic patches, checks,
drain, Longhorn handling, Talos operations, acceptance, and error reporting.

The existing Bash Lease implementation moves to a shared `scripts/lib/` location and
retains focused tests. A large inline Just implementation is rejected because the state
machine and failure injection would be difficult to test. A separate Python lifecycle
owner is also rejected because it would duplicate or split Lease ownership. Small pure
helpers remain possible only when a demonstrated parsing need justifies them.

Public commands share internal primitives but do not implement themselves by invoking
another public lifecycle command. Each transaction owns its confirmation, state,
failure boundary, and safety-critical rechecks.

## Resilience-test allocation

The application-specific `plex-node-reboot` test is retired. Its useful assertions remain
under `plex-cross-node-reschedule`, which already verifies:

- Plex replacement readiness on another node;
- unchanged PVC identity;
- Longhorn attachment to the landing node;
- persistence-marker survival; and
- SMB media remount.

The new `node-abrupt-loss` scenario is target-node-driven and cluster-scoped. It does not
depend on Plex being scheduled on the selected target. If Plex is affected, generic
workload and storage inventory observes it, while the durable Plex-specific contract
continues to belong to `plex-cross-node-reschedule`.

`node-abrupt-loss` is cataloged as a standalone operator-run resilience test. It is not
added to a frozen campaign because it requires explicit physical target selection and
two attended electrical actions.

## Command migration

The semantic moves update all repository-owned consumers in one change:

- root and module recipes;
- internal dependencies;
- scripts and fixtures;
- catalog entries and campaign membership;
- focused tests and validators;
- README command tables and examples;
- testing references;
- guides and runbooks; and
- the current repository command-lifecycle reference where needed.

Old public names, deprecated aliases, and parallel confirmation terminology are removed.
`plex-node-reboot` source, catalog registration, tests, and campaign references are also
removed.

Code must not be downgraded to a version that cannot interpret the lifecycle annotation
while any Node remains annotated or cordoned. Recovery with the matching implementation
must complete first.

## Validation

Cluster-independent validation uses economical table-driven and state-transition tests
instead of duplicating similar cases. Focused coverage proves:

- exact new command domains and removal of old names;
- confirmation and credential guards;
- observer read grants and continued mutation denial;
- Lease acquire, renew, ownership loss, expiry, and release behavior;
- lifecycle record parsing and fail-closed schema handling;
- optimistic concurrency on Node and Longhorn objects;
- every compare-and-restore branch;
- atomic Node containment and final acceptance patches;
- drain arguments and absence of eviction, PDB, unmanaged-pod, or storage bypasses;
- operation-specific reboot and maintenance storage behavior;
- failure containment before and after every material disruption boundary;
- absence of automatic uncordon cleanup;
- passive abrupt-loss observation, continuous probes, and separate primary/recovery
  outcomes;
- `retry-join` requested-member, exact-membership, and alarm postconditions;
- removal of `plex-node-reboot` with retained Plex reschedule coverage;
- standalone abrupt-loss catalog registration and campaign exclusion; and
- complete documentation migration without old public command names.

The implementation adds at most two new top-level offline harness cases:

- one node-lifecycle case for state transitions, ordered calls, failure injection,
  workload readiness, storage handling, and recovery; and
- one cluster-commands case for command migration, established verification composition,
  and the private pre-Cilium bootstrap prerequisite.

Existing Lease, bootstrap recovery, observer access, resilience-controller, catalog, and
dispatch suites are extended in place. State combinations and failure boundaries are
data rows or subtests inside those cases rather than separate process-heavy scripts. The
expected addition is approximately 40 to 60 logical rows across the new and extended
suites, not 40 to 60 new top-level test processes.

The CI runtime budget for this specification is:

```text
expected added runtime: no more than 7 seconds
review ceiling: 10 seconds or 1.5% of the current hosted just-ci median,
                whichever is lower
```

The focused lifecycle tests and a same-machine before-and-after `just ci` comparison are
reported during implementation review. This is a review budget, not a timing assertion
inside CI. If the focused additions exceed the ceiling, implementation must first remove
avoidable process starts, repeated parsing, rendering, or duplicated cases. An exception
requires a concrete coverage and runtime justification.

Offline lifecycle tests use fake command adapters, an injected clock, and immediate
fixture results. They perform no cluster access, network access, real sleep, watch, retry
delay, Helm render added solely for lifecycle coverage, or destructive action. Attended
reboot, maintenance, and electrical-loss validation remains outside CI and campaigns.

The canonical pre-merge gate remains:

```text
mise exec -- just ci
```

No destructive live cluster execution is required to prove implementation control flow
when command stubs and fixtures provide independent ordering and failure evidence.

## Live validation

Linked-worktree credentials cannot run disruptive validation. After merge and required
Flux reconciliation, operator-owned live validation increases disruption in this order:

1. Verify the updated scoped observer RBAC.
2. Run `cluster status`, `cluster verify`, and `maintenance-check` against each node.
3. Run one graceful `node reboot` transaction.
4. Run one `maintenance-enter`, physical power-on, and `maintenance-exit` cycle.
5. Run `node-abrupt-loss` last with actual electrical disconnection and restoration.

All three nodes must be fully established before advancing to the next disruptive step.
`node resize-longhorn` is not executed merely to validate its rename.

## Alternatives rejected

### Talos-owned client drain

Talos exposes client-side drain options, but that path owns cordon and uncordon behavior
without this repository's independent PDB, workload, Longhorn, persistent containment,
and recovery-acceptance contract. The repository therefore owns drain explicitly and
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

1. `maintenance-check` reports whether one selected node is safe to disrupt without
   mutation.
2. `maintenance-enter` safely drains, fully evacuates Longhorn replicas, shuts down, and
   leaves exactly one node persistently contained.
3. `maintenance-exit` restores lifecycle-owned state, accepts recovery, and uncordons as
   its final mutation.
4. `node reboot` performs a graceful drain without routine full replica evacuation and
   keeps failed recovery cordoned.
5. One shared Lease and persistent Node state enforce the one-node invariant across all
   qualifying workflows.
6. Failure semantics distinguish mutation, disruption, containment, recovery, and
   unresolved incident state without false rollback claims.
7. `node-abrupt-loss` passively measures a genuine electrical-loss event and separately
   reports recovery.
8. Plex-specific persistence coverage remains without `plex-node-reboot`.
9. Established node and cluster commands use only the new public domains, with no old
   aliases.
10. `cluster verify` composes core established-platform verification while the
    pre-Cilium gate remains private to bootstrap.
11. `bootstrap retry-join` remains exceptional and proves the requested healthy member
    result under shared serialization.
12. Scoped identities gain required observations but no disruptive authority.
13. Focused cluster-independent tests and `mise exec -- just ci` pass within the approved
    incremental runtime budget.
14. The specification is reconciled with the implemented and validated result before
    merge.

## Consequences

Routine node operation becomes orderly and recoverable: the cluster proves it can lose
one node, drains workloads, contains the target, accepts its return, and only then makes
it schedulable. Planned maintenance can span an arbitrary physical-work interval without
holding an active Lease. Reboot remains efficient by preserving reusable replicas.

The repository also retains honest high-availability evidence. Abrupt electrical loss
is tested explicitly without graceful preparation, application-specific Plex coverage
stays with the Plex scenario, and passive behavior remains distinguishable from incident
intervention.

The design adds operational machinery and attended validation, but it avoids an
in-cluster controller, another persistent resource, a transaction journal, compatibility
aliases, and broader agent authority. The resulting lifecycle is explicit enough to
recover safely while remaining proportional to a three-node homelab cluster.
