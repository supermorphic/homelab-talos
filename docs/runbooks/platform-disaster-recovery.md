# Recover the platform after workstation or cluster loss

## Trigger

Use this runbook when rebuilding the operator environment or foundational cluster state
after workstation loss, generated-credential loss, Talos or control-plane failure, Flux
source or bootstrap loss, or storage and application-state loss that is part of broader
platform reconstruction.

Do not use it for an ordinary application incident. qBittorrent VPN failures belong in
[Operate qBittorrent VPN egress](../guides/qbittorrent-vpn-operations.md), and an
incorrect qbit_manage cleanup belongs in
[Recover a qbit_manage mistaken clean](qbit-manage-mistaken-clean.md).

## Recovery model

First decide whether the existing cluster is healthy:

```text
Is the existing cluster healthy?
        │
        ├─ yes
        │   → rebuild the workstation
        │   → restore the operator-held age identity
        │   → regenerate local Talos and Kubernetes credentials
        │   → verify the existing platform
        │   → stop
        │
        └─ no
            ↓
        recover Talos and etcd
            ↓
        establish Cilium networking
            ↓
        restore Flux source access
            ↓
        restore Flux SOPS decryption
            ↓
        recover Longhorn and application state
            ↓
        verify the complete platform
```

Do not recover a higher layer while a prerequisite layer is unhealthy. Restore one
layer, verify it, and only then continue upward. This dependency order is why Talos,
Cilium, Flux, SOPS, and Longhorn recovery remain in one runbook.

## Authority and global safety

Run recovery from the operator-controlled primary checkout with the administrator
credentials required by the guarded workflow. Do not put administrator credentials in a
linked worktree.

| Operation | Effect and authority |
| --- | --- |
| Repository and toolchain setup | Local workstation setup; follow the repository setup guide. |
| Load the SOPS identity | Uses an operator-held private identity outside the repository. |
| `repo secrets`, `talos generate`, and `talos kubeconfig` | Validate identity and regenerate ignored local configuration; operator-run where the age identity or administrator credential is required. |
| Status and verifier commands | Read-oriented diagnosis; credential requirements vary by verifier. |
| `bootstrap retry-join` | Guarded reboot of one failed non-bootstrap etcd join; operator live mutation. |
| `talos apply <node>` | Destructive, target-bound reinstall of one maintenance-mode node; operator action. |
| `bootstrap cilium` before Flux ownership | Guarded bootstrap mutation from the canonical tracked values. |
| Cilium repair after Flux ownership | Reviewed Git change and Flux reconciliation; the bootstrap workflow refuses parallel ownership. |
| `bootstrap flux-ssh-known-hosts` | Narrow live repair that preserves the existing Flux deploy identity. |
| `bootstrap flux` | Operator recovery that uses a temporary GitHub credential to recreate the read-only Flux deploy identity. |
| `bootstrap flux-sops` | Reads or restores the matching in-cluster age identity; operator secret and live-state access. |
| Longhorn restore or production claim replacement | Operator storage mutation after isolated restore validation. |

Confirmation variables are execution guards. They do not determine authority. Never
work around a failed guard with raw `talosctl`, `kubectl`, `helm`, or `flux` mutation.

## Choose the recovery path

### Workstation-only loss

If Talos, Kubernetes, Cilium, Flux, and storage are already healthy, restore only the
operator environment:

```text
fresh current clone
→ pinned toolchain
→ matching age identity
→ generated Talos config
→ administrator kubeconfig
→ platform verification
→ stop
```

Do not reinstall nodes, bootstrap Cilium or Flux, or restore storage merely because
those sections appear later in this document.

### Platform reconstruction

If a foundational cluster layer is unhealthy, run the read-only checks that are
available, identify the lowest unhealthy layer, and begin there:

```bash
mise exec -- just bootstrap status
mise exec -- just talos volume-status
mise exec -- just kube cilium-status
mise exec -- just kube flux-status
mise exec -- just kube foundation-status
```

Some commands will fail when their prerequisite is unavailable. That failure helps
locate the recovery boundary; it is not permission to skip the failed layer.

## Rebuild the operator workstation

Use a fresh, current clone and follow
[Repository and worktree setup](../guides/repository-worktree-setup.md) for the canonical
toolchain and primary-checkout procedure.

For disaster recovery:

- review the clone and establish the pinned toolchain before trusting its workflows;
- validate the source before using it for live recovery;
- do not copy ignored `clusterconfig/`, `.talos/config`, `.kube/config`, or stale
  credentials from an old worktree; and
- keep the operator-held age identity outside every checkout and worktree.

The setup guide owns the normal installation commands. Return here after the primary
checkout is ready.

## Restore SOPS and generated Talos state

Follow [Operate repository SOPS secrets](../guides/sops-secret-operations.md) to load the
matching age identity without storing it in the repository. Then validate the identity
and regenerate ignored Talos state:

```bash
mise exec -- just repo secrets
mise exec -- just talos generate
```

`repo secrets` proves that the loaded private identity derives the recipient configured
in `.sops.yaml`. `talos generate` decrypts the tracked
`talos/talsecret.sops.yaml` only for rendering, recreates ignored machine configurations
under `clusterconfig/`, installs the ignored administrator `.talos/config`, and validates
the result. It reuses the durable Talos identity; it does not create a new one.

When an existing API is reachable, recreate the ignored Kubernetes administrator
configuration from Talos:

```bash
mise exec -- just talos kubeconfig
```

The `.talos/config`, `.kube/config`, and rendered machine files are disposable local
outputs. The matching age identity and encrypted Talos identity bundle are not. If the
matching age private identity is lost, current ciphertext cannot be recovered normally.
Do not regenerate `talos/talsecret.sops.yaml` or create a new cluster identity as a
shortcut. Stop and escalate.

Unset a shell-exported `SOPS_AGE_KEY` when the operator task is complete.

## Recover Talos and etcd

Talos and etcd are the first live cluster prerequisite. Start with:

```bash
mise exec -- just bootstrap status
mise exec -- just talos volume-status
```

Do not replay etcd bootstrap, remove a member, or use blind reboot loops. The repository
does not provide an ordinary recovery workflow for lost etcd quorum. If quorum is lost
or member removal or snapshot restoration appears necessary, stop for a separately
reviewed recovery plan.

### Retry a failed initial non-bootstrap join

This workflow is only for `nuc2` or `nuc3` during an initial join. Inspect the exact node:

```bash
mise exec -- just bootstrap status <node>
```

The guarded retry independently proves that:

- the node is not already an etcd member;
- its etcd service state is `Failed`; and
- its discovery view contains exactly the three expected nodes.

Run the recipe without inventing a guard value. Use only the exact target-bound
confirmation printed by the current workflow:

```bash
mise exec -- just bootstrap retry-join <node>
```

Then rerun it with the printed `TALOS_ETCD_RETRY_CONFIRM` value. The confirmed action
reboots only that failed non-bootstrap node so Talos can retry its normal join. It does
not bootstrap etcd or remove a member. After the node returns, rerun `bootstrap status`
and require the exact three-member set.

### Reinstall one failed Talos node

Use `mise exec -- just talos apply <node>` only when the exact node is booted in Talos
maintenance mode for reinstall. This workflow wipes the selected system disk. It is not
the ordinary live machine-configuration workflow.

Before reinstalling:

1. Prove the remaining nodes retain etcd quorum and have no etcd alarms.
2. Prove the exact target node, hardware, Secure Boot state, and system disk.
3. Prove required application state has another healthy Longhorn replica or a verified
   backup.
4. Run `mise exec -- just talos apply <node>` without confirmation. Review its source
   validation, live hardware identity, Talos dry run, and generated target-specific
   confirmation.
5. Rerun only with the exact confirmation generated for that node.
6. Wait for the node to rejoin before disturbing any other node.

After it returns, verify Talos services, the exact etcd member set, node volumes, Cilium,
Flux, foundation services, and Longhorn replica rebuild. Stop if another node is
unhealthy or the first node has not fully recovered.

Routine planned reboots and ordinary `talos apply-live` changes are outside this
disaster-recovery runbook. Follow the current Talos source documentation and its guarded
workflows for planned maintenance.

## Establish Cilium networking

Continue only after Talos and etcd are healthy:

```bash
mise exec -- just kube cilium-status
mise exec -- just kube cilium-diagnostics
```

If Cilium is healthy, continue to Flux. If it is unhealthy, first identify its owner.

### Before Flux owns Cilium

On a bare or pre-Flux cluster, `mise exec -- just bootstrap cilium` validates the
canonical source and live prerequisites. It refuses a competing CNI, unmanaged Cilium
resources, unexpected nodes, or an existing Flux Cilium HelmRelease. Run the preflight,
review the exact confirmation it prints, and authorize only that canonical bootstrap.

### After Flux owns Cilium

Once the Cilium HelmRelease exists, the bootstrap recipe intentionally refuses to act as
a second reconciler. Repair source through reviewed Git and let Flux reconcile it. Do
not uninstall a functioning CNI or install a second CNI as a workaround.

If Flux-owned Cilium is too unhealthy for Flux itself to recover, stop. The repository
has no supported parallel-owner shortcut for that circular failure.

For either supported path, verify before continuing:

```bash
mise exec -- just kube cilium-verify
mise exec -- just kube cilium-postflight
```

## Restore Flux source and decryption

Continue only after the Kubernetes API and Cilium are healthy. Diagnose the failure
before replacing credentials:

```bash
mise exec -- just kube flux-status
```

Treat source access and SOPS decryption as separate branches.

### Repair only SSH host trust

If the GitRepository uses the expected SSH deploy identity but reports
`knownhosts: key is unknown`, preserve the deploy key and repair only `known_hosts`:

```bash
mise exec -- just bootstrap flux-ssh-known-hosts
```

Review the preflight and rerun only with the exact
`FLUX_SSH_KNOWN_HOSTS_CONFIRM` value it prints. The workflow verifies the expected
port-443 source URL and published host fingerprint, preserves the public deploy key,
reconciles the source, and requires it to become Ready. Do not replace a working deploy
identity merely to repair host trust.

### Recover a missing deploy key or Flux bootstrap state

Use a fresh/current primary checkout and a temporary repository-scoped GitHub token.
The current guarded workflow requires repository Administration and Contents write
access so it can create the deploy key and bootstrap source. It verifies that the
resulting GitHub deploy key is read-only.

```bash
export GITHUB_TOKEN='<temporary-repository-scoped-token>'
mise exec -- just kube flux-preflight
mise exec -- just bootstrap flux
```

Review the preflight and rerun bootstrap only with the exact
`FLUX_BOOTSTRAP_CONFIRM` value it prints. Flux retains the read-only SSH identity, not
the temporary GitHub token. Remove both values from the shell after recovery:

```bash
unset FLUX_BOOTSTRAP_CONFIRM GITHUB_TOKEN
```

### Restore Flux SOPS decryption

If `flux-system/sops-age` is absent and the operator still holds the matching age
identity, follow the guarded recovery in
[Operate repository SOPS secrets](../guides/sops-secret-operations.md):

```bash
mise exec -- just bootstrap flux-sops
```

The workflow first validates the workstation identity against `.sops.yaml`. If the live
Secret already has the expected recipient, it makes no change. If the Secret is absent,
rerun only with the printed `FLUX_SOPS_CONFIRM` value to create it.

A different live recipient is not ordinary recovery. The workflow refuses to overwrite
it. Preserve the old identity and ciphertext, stop, and design a reviewed key-rotation
and re-encryption change.

Verify Flux source access, controller readiness, reconciliation, SOPS decryption, and
the permanent canary before continuing:

```bash
mise exec -- just kube flux-verify
```

## Recover Longhorn and application state

Continue only after Talos, etcd, Cilium, and Flux are healthy:

```bash
mise exec -- just talos volume-status
mise exec -- just kube storage-verify
```

Longhorn uses two replicas on different nodes and daily snapshots and off-cluster
backups from the built-in `default` group, each retained for seven runs. Longhorn
replication is not a backup.

### Let a returned node rebuild replicas

After one node returns, allow Longhorn to rebuild its missing replicas. Require affected
volumes to become healthy before disturbing another node. Do not create a second
simultaneous node-recovery event while replica redundancy is degraded.

### Recover a lost application claim

1. Identify the expected claim and application contract from current Git.
2. Confirm the backup target is healthy and select a verified backup.
3. Restore into a **new** claim through an approved Longhorn operator procedure.
4. Validate the restored data with an isolated workload or application-specific check.
5. Only after isolated validation, reconnect or replace production state through a
   reviewed recovery change.
6. Reconcile the application and run its dedicated verifier.

The repository currently verifies backup-target and recurring-job configuration, but it
does not automate a claim restore or prove restored application data. Stop before
replacing a production claim if the new claim has not passed isolated validation.

### Plex state

Plex is single-active: its Deployment uses `Recreate`, and its configuration claim uses
`ReadWriteOncePod`. Preserve the server identity and library database when restoring the
claim. A replacement that starts as a different server or empty library is not a
successful restore.

After the claim is healthy and Plex has reconciled, run:

```bash
mise exec -- just kube plex-verify
```

This proves the current Kubernetes and application-health assertions; it does not by
itself prove that the restored library history is complete. Use the applicable
application-specific acceptance evidence as well.

For another media application, prefer a trusted Longhorn or application-native backup.
Use [Media automation setup](../guides/media-automation-setup.md) as a greenfield fallback
only when no trusted configuration backup exists. Do not replace a recoverable stateful
application with empty first-run state merely because greenfield setup is documented.

## Verify the recovered platform

Disaster recovery is complete only when every recovered dependency and required
stateful application is healthy. Run the applicable canonical checks in order:

```bash
mise exec -- just bootstrap status
mise exec -- just talos volume-status
mise exec -- just kube cilium-verify
mise exec -- just kube cilium-postflight
mise exec -- just kube flux-status
mise exec -- just kube flux-verify
mise exec -- just kube foundation-status
mise exec -- just kube foundation-verify
mise exec -- just kube storage-verify
```

Then run the dedicated verifier and functional acceptance for each recovered stateful
application. Flux Ready status alone does not prove node storage, decrypted application
state, or application-level recovery.

If recovery changed Git, run the canonical cluster-independent gate before the Git
change is complete:

```bash
mise exec -- just ci
```

Record only sanitized outcomes. Do not publish credentials, generated configuration,
backup contents, or unique infrastructure identifiers.

## Global stop boundary

Stop whenever recovery requires broader credentials, destructive action, live mutation,
or identity replacement beyond a documented guarded workflow. In particular, stop
before:

- replacing the age or Talos identity to bypass missing credentials;
- replaying etcd bootstrap, removing a member, or threatening quorum;
- disturbing another node while the first remains unhealthy;
- forcing a second Cilium owner;
- overwriting a mismatched Flux SOPS identity; or
- replacing a production claim without a verified isolated restore.

Do not improvise around a failed recovery guard. Escalate with sanitized evidence from
the lowest unhealthy layer.
