# Phase 4: Bootstrap Talos and Kubernetes

## Status

- Started: 2026-07-18
- Completed: 2026-07-18
- State: Complete
- Bootstrap node: `nuc1` at `192.168.90.10`
- Etcd bootstrap invocations completed: 1
- Cilium at Phase 4 completion: not installed; installed in Phase 5 on 2026-07-19

Phase 4 creates the new etcd and Kubernetes control-plane state exactly once. It
does not install a CNI, Flux, applications, or storage controllers. Kubernetes
nodes are expected to remain `NotReady` until Phase 5 installs Cilium.

## Just Interface

All operational commands are implemented in `.just/bootstrap.just`. Operators
do not run raw `talosctl bootstrap`, `talosctl kubeconfig`, `talosctl etcd`, or
`kubectl` commands during this workflow.

| Command | Behavior |
|---|---|
| `just bootstrap preflight` | Read-only validation of all three NUCs and confirmation that etcd is not initialized |
| `just bootstrap talos` | Repeats preflight, requires the exact nuc1 confirmation, and invokes bootstrap once |
| `just bootstrap status [node]` | Prints read-only etcd membership, service state, discovery members, and recent etcd logs; defaults to all nodes |
| `just bootstrap retry-join <node>` | Reboots a failed nuc2/nuc3 join only after membership, service, discovery, and explicit-confirmation guards |
| `just bootstrap verify` | Waits for three-member etcd, checks health/leader/alarms, refreshes kubeconfig, and validates the full Phase 4 gate |

Without an activated mise shell, prefix each command with `mise exec --`.

## Exactly-Once Guard

The preflight requires:

1. The ignored generated `.talos/config` contains exactly the nuc1, nuc2, and
   nuc3 endpoints.
2. Every rendered Talos config still passes strict Phase 2 validation.
3. All three authenticated APIs report the expected hostname, internal UKI boot,
   Secure Boot state, Samsung system disk, ready encrypted volumes, Longhorn
   mount, expected extensions, synchronized time, healthy baseline services,
   and no diagnostics.
4. No USB disk is present on any node.
5. No etcd member resources exist on nuc1.

The mutating recipe then requires this exact operator confirmation:

```bash
TALOS_BOOTSTRAP_CONFIRM='bootstrap:nuc1:192.168.90.10' \
  just bootstrap talos
```

After bootstrap succeeds, the live etcd-member guard prevents the recipe from
running again. Recovery from a partial or failed bootstrap is not automatic and
must not be attempted by blindly rerunning the command.

If a non-bootstrap node's etcd service times out before it can discover the
initial member, `just bootstrap status <node>` records the failure. The guarded
`just bootstrap retry-join <node>` recipe is limited to nuc2/nuc3, refuses an
existing member or running service, requires exact three-node discovery, and
reboots only that failed non-member so Talos reruns its normal service lifecycle.
It never invokes bootstrap or removes a member.

## Verification Contract

`just bootstrap verify` waits up to five minutes for convergence and then
requires:

- Exactly three etcd members and exactly one elected leader.
- Successful etcd status from all three nodes and no alarms.
- An owner-readable ignored `.kube/config` retrieved through Talos.
- Kubernetes API access through `https://192.168.90.20:6443`.
- Exactly `nuc1`, `nuc2`, and `nuc3`, all labeled control planes and `NotReady`
  before Cilium.
- Synchronized time and healthy `apid`, `containerd`, `cri`, `etcd`, `kubelet`,
  and `machined` services on every node.
- Secure Boot plus UKI boot, ready encrypted STATE and EPHEMERAL volumes, and the
  mounted 837 GB XFS Longhorn volume on every node.
- No Talos diagnostics.

## Acceptance Evidence

| Check | Result |
|---|---|
| Phase 4 preflight | Pass on all three nodes |
| Exactly-once nuc1 bootstrap | Pass; one invocation accepted |
| Three etcd members | Pass; nuc1, nuc2, and nuc3 are voting members |
| One leader and no alarms | Pass |
| Kubeconfig and API VIP | Pass at `https://192.168.90.20:6443` |
| Three expected `NotReady` nodes | Pass; expected before Cilium |
| Time, services, encryption, and mounts | Pass on all three nodes |

The unconfirmed bootstrap rehearsal passed preflight and refused the mutation
without `TALOS_BOOTSTRAP_CONFIRM`. The confirmed invocation then bootstrapped
nuc1 exactly once. A post-bootstrap invocation was rejected by the live member
guard before reaching its confirmation or bootstrap command.

nuc1 and nuc3 converged first. nuc2's etcd service had timed out in its join
pre-stage before the initial member was available and remained `Failed`. The
read-only `just bootstrap status nuc2` recipe confirmed that nuc2 was not a
member, that all three discovery members were visible, and that no etcd process
had started. A service restart was rejected by Talos because etcd does not expose
that lifecycle operation; no state changed. The guarded reboot confirmation then
rebooted only nuc2, causing Talos to rerun its normal join lifecycle. nuc2 joined
as the third voting member without another bootstrap or member removal.

Final etcd status reported three members on protocol `3.6.12` and storage
`3.6.0`, the same leader and Raft index on every member, no learners, no errors,
and no alarms. The verifier atomically wrote the ignored workstation
`.kube/config` with mode `0600` and successfully queried the VIP-backed
Kubernetes API.

Phase 5 subsequently implemented the canonical Cilium values and guarded install
workflow. See [`phase-5-cilium.md`](phase-5-cilium.md) for live acceptance
evidence.
