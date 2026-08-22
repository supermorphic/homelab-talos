# Recover the Talos and Flux platform

Use this runbook after workstation loss, credential loss, failed Talos or etcd state,
Flux source failure, storage failure, or a stateful application recovery event. Start
with read-only diagnosis. Use the guarded repository workflow for any mutation.

Administrator credentials, destructive node operations, secret creation, Longhorn
restore, and persistent live-state changes are operator actions. Git remains the source
of truth for Flux-managed state.

## Recover the repository and toolchain

Clone the repository, review its configuration, and install the locked toolchain:

```bash
brew install mise
mise trust
mise install --locked
mise exec -- just repo hooks
mise exec -- just ci
```

Do not recover ignored generated configuration or credentials from an old worktree.
Recreate them from current Git and approved credential sources.

## Restore SOPS and generated Talos state

Retrieve the password-manager item `homelab-talos SOPS age key`. Load it for one shell or
point SOPS to an owner-readable file outside the repository:

```bash
export SOPS_AGE_KEY='AGE-SECRET-KEY-...'
# or: export SOPS_AGE_KEY_FILE=/secure/path/homelab-talos-age.txt
mise exec -- just repo secrets
mise exec -- just talos generate
```

The generation workflow recreates ignored machine configurations and the Talos client
credential, then validates the source. Never commit plaintext copies of generated
machine files, `.talos/config`, `.kube/config`, or the age identity.

A lost private age key makes current encrypted repository values unrecoverable. Stop and
escalate rather than regenerating `talos/talsecret.sops.yaml`; regeneration creates a
different Talos cluster identity.

## Diagnose node and etcd state

Use current read-only status first:

```bash
mise exec -- just bootstrap status
mise exec -- just talos volume-status
mise exec -- just kube flux-status
mise exec -- just kube foundation-status
```

For a failed initial etcd join on `nuc2` or `nuc3`, inspect that node specifically:

```bash
mise exec -- just bootstrap status <node>
```

Only when the guarded workflow confirms the node is not an etcd member, its etcd service
is failed, and all three discovery members are present, run the exact confirmation it
requires:

```bash
TALOS_ETCD_RETRY_CONFIRM='retry-etcd-reboot:<node>:<node-address>' \
  mise exec -- just bootstrap retry-join <node>
```

This reboots only a failed non-bootstrap node. It never reruns etcd bootstrap or removes
a member. Never rerun `just bootstrap talos` against an initialized cluster.

For an ordinary planned reboot, use the cluster-health-gated workflow:

```bash
TALOS_REBOOT_CONFIRM='reboot:<exact-value-from-the-workflow>' \
  mise exec -- just bootstrap reboot <node>
```

The workflow must confirm three Ready nodes, three etcd members, and no alarms before it
removes one node. Do not proceed when another node is unhealthy.

## Recover a Talos node

Use `mise exec -- just talos apply-live <node>` for an approved machine-configuration
change to a running node. Use `mise exec -- just talos apply <node>` only from Talos
maintenance mode when reinstalling that exact node; it wipes the selected system disk
after a hardware-derived confirmation.

Before reinstalling:

1. Confirm the exact node, expected system disk, Secure Boot state, and current cluster
   quorum.
2. Confirm application state has another healthy Longhorn replica or a verified backup.
3. Run the command without confirmation and review the printed target-specific guard.
4. Repeat with the exact confirmation only after the preflight passes.
5. After the node rejoins, verify Talos services, etcd membership, Cilium, Flux,
   foundation, and Longhorn replica rebuild.

Do not use a confirmation copied from another node.

## Recover Cilium

Start with:

```bash
mise exec -- just kube cilium-status
mise exec -- just kube cilium-diagnostics
```

Do not uninstall a functioning CNI or install a second CNI as a workaround. Before Flux
owns Cilium, the guarded `mise exec -- just bootstrap cilium` interface can install or
reconcile the canonical chart values. After Flux owns the HelmRelease, make Cilium
changes through Git and Flux; the bootstrap recipe intentionally refuses to become a
second reconciler.

Verify recovery with:

```bash
mise exec -- just kube cilium-verify
mise exec -- just kube cilium-postflight
```

## Recover Flux source access

Flux uses the private key in `Secret/flux-system` with the matching read-only GitHub
deploy key. The canonical source URL is
`ssh://git@ssh.github.com:443/supermorphic/homelab-talos`.

If source-controller reports `knownhosts: key is unknown`, preserve the deploy key and
repair only host trust:

```bash
FLUX_SSH_KNOWN_HOSTS_CONFIRM='repair:flux-system:known-hosts:ssh.github.com:443' \
  mise exec -- just bootstrap flux-ssh-known-hosts
```

If the deploy key or cluster Secret is lost, load a temporary repository-scoped GitHub
token and run the guarded recovery:

```bash
export GITHUB_TOKEN='<repository-scoped-token>'
export FLUX_BOOTSTRAP_CONFIRM='bootstrap:flux:prod:supermorphic/homelab-talos:read-only'
mise exec -- just kube flux-preflight
mise exec -- just bootstrap flux
unset FLUX_BOOTSTRAP_CONFIRM GITHUB_TOKEN
```

The token needs repository Administration and Contents write access only for bootstrap
to create the deploy key and source. Flux stores the read-only SSH deploy identity, not
the token.

Verify with:

```bash
mise exec -- just kube flux-status
mise exec -- just kube flux-verify
```

Use the confirmation-guarded Flux canary only when current decryption and reconciliation
need an end-to-end mutation proof.

## Recover Flux SOPS access

If `flux-system/sops-age` is absent and the operator still holds the matching identity:

```bash
export SOPS_AGE_KEY='AGE-SECRET-KEY-...'
export FLUX_SOPS_CONFIRM='create:flux-system:sops-age'
mise exec -- just bootstrap flux-sops
unset FLUX_SOPS_CONFIRM SOPS_AGE_KEY
```

The workflow refuses to overwrite a Secret derived from another recipient. Treat that
condition as a planned key rotation, not ordinary recovery. Preserve the old key and
design a reviewed re-encryption workflow before changing the live identity.

For Pi-hole or Cloudflare credential recovery, follow
[Maintain the Pi-hole integration](../guides/pihole-integration.md). For other encrypted
application credentials, use only the application's established SOPS writer.

## Recover Longhorn and application state

Check node volumes and Longhorn first:

```bash
mise exec -- just talos volume-status
mise exec -- just kube storage-verify
```

After one node returns, allow Longhorn to rebuild the missing replica and require the
volume to return healthy before disrupting another node.

For a lost application claim:

1. Identify the exact application and expected claim from current Git.
2. Confirm the backup target is healthy and select a verified backup.
3. Restore into a new claim through an approved Longhorn operator procedure.
4. Validate the restored data with an isolated workload or application-specific restore
   check before replacing the production claim.
5. Reconcile the application and run its dedicated verifier.

Longhorn replication is not a backup. The `default` recurring jobs supply daily
snapshots and off-cluster backups. Bulk media is NAS-owned and is not part of application
config-volume backups.

Plex is single-active. Node loss can cause a minutes-long outage while Kubernetes evicts
the old pod and Longhorn reattaches its `ReadWriteOncePod` claim. After recovery, require
the same Plex server identity and library, a healthy config claim, and:

```bash
mise exec -- just kube plex-verify
```

For another media application, prefer its trusted Longhorn or application-native backup.
Use [Media automation greenfield startup](../guides/arr-stack-startup.md) only when no
trusted configuration backup exists.

## Recover qBittorrent VPN egress

When `QbittorrentVpnDown` or `QbittorrentGluetunRestartLoop` fires, first confirm that
Gluetun remains fail-closed and that qBittorrent is not using the residential route.
Gluetun normally reconnects, reacquires a forwarded port, and applies it to qBittorrent.

If status remains running but the forwarded port is missing, the slow liveness check may
restart the Gluetun container. Repeated restart-loop alerts require an operator-managed
pod recreation, which supplies a fresh process and network namespace. Do not disable
encrypted DNS or the firewall as a recovery shortcut.

After recovery, run:

```bash
mise exec -- just kube qbittorrent-verify
```

Require VPN status `running`, Sweden egress, a nonzero forwarded port applied to
qBittorrent, and no residential-address leak. Avoid rapid repeated reconnect tests;
provider rate limiting can obscure the original failure.

## Escalation

Stop and escalate when recovery would require:

- changing or regenerating the Talos identity;
- overwriting a mismatched SOPS identity;
- removing an etcd member or rerunning bootstrap;
- disrupting a second node before the first is healthy;
- deleting or replacing a production claim without a verified restore;
- using elevated credentials not authorized for the task; or
- making a persistent live-state change outside Git without operator authority.

After recovery, run the affected verifiers and `mise exec -- just ci` for any Git change.
Record sanitized outcomes only.
