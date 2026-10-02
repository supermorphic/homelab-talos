# Node Lifecycle and Maintenance

## Purpose

Disrupt one established node safely in the three-node Talos/Kubernetes/etcd/Cilium/
Longhorn cluster. Graceful reboot, arbitrary-duration physical maintenance, and attended
unprepared electrical-loss testing have different storage and evidence contracts but
share recovery acceptance. [Command semantics](021-repository-command-lifecycle.md) and
[repository policy](../../AGENTS.md) govern their effects and authority.

## Operational boundary

[Node recipes](../../.just/node.just), [the lifecycle controller](../../scripts/node/lifecycle.sh),
and [the abrupt-loss runner](../../scripts/test/scenarios/node_abrupt_loss.py) own syntax,
record schema, timeouts, and exact guards. Observational maintenance-check and cluster
status/verify use approved scoped credentials. Mutating lifecycle and electrical-loss
workflows require operator-controlled administrative credentials and refuse scoped
linked-worktree execution; confirmation does not grant that authority.

Reboot drains workloads and preserves reusable replicas for a short outage. Maintenance
entry records and disables replica scheduling, drains and fully evacuates replicas, then
shuts down and deliberately leaves the node offline. The operator physically starts it
before maintenance-exit. Longhorn resize retains its guarded destructive two-reboot
transaction under shared serialization; a rename does not authorize a live resize test.

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

### Transient ownership

The renewable `flux-system/homelab-test-run-lock` serializes node lifecycle,
qualifying topology changes, and mutating test orchestration. Retaining one identity
prevents workflows from using separate locks.

The Lease protects only an active transaction, including reboot, maintenance entry/exit,
Longhorn resize, abrupt-loss testing, join retry, and qualifying mutating campaigns.

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

The record identifies supported lifecycle kind; maintenance additionally retains observed
Longhorn values before entry and intended values during absence. Exact record fields and
schema belong to [the lifecycle controller](../../scripts/node/lifecycle.sh).

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

Observational preflight must not require eviction or Node-patch authority. The real
operator transaction repeats capability checks and evicts only after persistent containment.

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
Replacement readiness has a bounded wait. Exhaustion preserves containment and prevents
shutdown.

For Plex, these generic checks use its existing `/identity` readiness probe, require the
same Longhorn-backed configuration volume to attach on the landing node, and require the
SMB media volume to mount. Its termination grace allows an orderly SQLite shutdown. Its `emptyDir` transcode data is reported and discarded, so an active
stream or transcode can be interrupted even though the workload transition is graceful.
The lifecycle does not create a Plex persistence marker or duplicate the complete
`plex-cross-node-reschedule` resilience test.

A blocked or timed-out drain stops before reboot or shutdown. The node remains annotated
and cordoned for recovery through `maintenance-exit`.

The reviewed Talos CLI has an optional `reboot --drain` path. Its implementation
cordons and drains before reboot, then uses deferred cleanup to uncordon even when a
later stage fails. That behavior conflicts with persistent containment, so `node reboot`
does not pass `--drain`.

The reviewed Talos `shutdown` behaves differently: it performs its own cordon and drain unless
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

Establish healthy baseline and continuous external probes, request electrical removal,
prove genuine multi-plane loss, then contain the already-offline Node. Observe autonomous
recovery passively, request electrical restoration, and require full recovery before
final acceptance. Default degraded observation preserves surviving replicas without
requiring full reconstruction during absence; complete convergence is required afterward.
Singleton recovery is measured separately from core-path continuity.

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
intentional node disruption. Repair or reinstall follows the [platform recovery boundary](010-talos-flux-platform.md#independent-platform-recovery), after which `maintenance-exit` can accept a supported persisted lifecycle
record. Permanent replacement or etcd-member removal requires a separate reviewed plan.

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


## Recover contained lifecycle state

After a failed reboot, maintenance return, or abrupt-loss test, correct the blocking
condition and physically start the node when necessary. Inspect its persisted lifecycle
kind and use the matching administrative implementation:

```bash
NODE_LIFECYCLE_CONFIRM='accept:<node>:<kind>' \
  mise exec -- just node maintenance-exit <node>
```

Only supported `maintenance`, `reboot`, and `abrupt-loss` records for the exact node can
be accepted. Recovery restores owned Longhorn settings while still cordoned and makes
annotation removal/uncordon the final accepted mutation. Never downgrade to code unable
to interpret a record while any node is contained. An unknown/malformed annotation key
blocks admission even if its value cannot be parsed; a free Lease never overrides it.

## Coordination and validation

Lease operations use optimistic resource-version ownership; only the current holder can
renew or release, and release clears holder without deleting the object. Conflicts require
fresh reads; expiry never authorizes overwriting a newer claim. Campaign children verify
the exported parent and never release it. Renewal failure creates a failure signal checked
with current holder immediately before mutation. Publication uses an independent Lease.

Offline tests use injected commands/clocks and independent transition, failure, and
concurrency oracles without live access. They must detect mutation before authority,
eviction/PDB bypass, inconsistent restore, lost ownership, false rollback after disruption,
and uncordon before acceptance. Native acceptance is separate: verify scoped RBAC and
observational checks, then one graceful reboot, a maintenance cycle, and electrical loss
last. Reestablish all three nodes between disruptions; do not exercise destructive resize
merely to prove its interface.

Plex-specific persistence and SMB remount evidence stays with its cross-node reschedule
test; cluster lifecycle checks affected workloads without turning arbitrary application
health into an aggregate platform invariant. Electrical loss remains standalone because
it requires explicit physical target selection and attended removal/restoration.

Repository-owned drain is deliberate: Talos client cleanup can uncordon before this
contract accepts recovery. Full replica evacuation for every reboot would discard usable
replicas and impose unnecessary reconstruction. A separate lifecycle custom resource,
controller, or transaction journal would introduce synchronization without a current need.
The Node's minimal recovery record and shared internal primitives are sufficient; each
public operation owns its transaction rather than naively chaining public commands.
