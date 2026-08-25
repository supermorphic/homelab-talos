# Operate repository SOPS secrets

This guide explains how an operator creates, changes, and recovers encrypted
repository secrets. It also explains why ordinary source work and normal Flux
reconciliation do not need the operator's private age identity.

Repository policy is defined in [`AGENTS.md`](../../AGENTS.md). The recipes and scripts
referenced here enforce the current implementation. Integration guides supply the exact
inputs and acceptance steps for individual applications.

## Secret flow

SOPS encrypts protected values for an age recipient. An age recipient is a public key
that is safe to commit. Its matching private identity is the key that can decrypt the
values.

```text
operator-held age private identity
        ↓
local SOPS encryption or decryption
        ↓
Git stores ciphertext only
        ↓
pull request → protected main
        ↓
Flux uses flux-system/sops-age
        ↓
Kubernetes Secret
```

The private identity has two separate uses:

- On the operator workstation, it lets approved repository workflows create or decrypt
  protected repository material.
- In the cluster, the `flux-system/sops-age` Secret lets Flux decrypt ciphertext that is
  already committed to Git.

Agents and ordinary source-only work do not receive or need the operator identity.
Normal Flux reconciliation uses the cluster-side copy; it does not reach back to the
operator workstation.

## What Git may contain

Expected public repository content includes:

- [`.sops.yaml`](../../.sops.yaml), including the public age recipient;
- SOPS ciphertext and its encryption metadata;
- reviewable Kubernetes Secret metadata; and
- the fully encrypted Talos identity bundle at
  [`talos/talsecret.sops.yaml`](../../talos/talsecret.sops.yaml).

The current policy encrypts the complete Talos identity document. Kubernetes
`*.sops.yaml` files encrypt only `data` and `stringData`, so names, labels, namespaces,
and other non-secret metadata remain reviewable.

Never commit:

- the age private identity;
- plaintext application credentials or decrypted Secret files;
- plaintext Talos identity material;
- generated machine configuration;
- kubeconfigs or talosconfigs; or
- other private keys or credential-bearing output.

Keep the operator identity in the operator's password manager or another approved
private store. Do not put it in the repository, a linked worktree, or a committed shell
configuration file.

## When the age identity is required

Load the operator identity only when a workflow must access protected repository
material. Current examples include:

- creating or rotating an encrypted application Secret through a repository writer;
- generating ignored Talos configuration with
  `mise exec -- just talos generate`;
- checking that the operator restored the correct identity with
  `mise exec -- just repo secrets`; and
- restoring a missing `flux-system/sops-age` Secret through the exceptional guarded
  Flux recovery workflow.

Examples of application writers include the ProtonVPN credential workflow described in
[Operate qBittorrent VPN egress](qbittorrent-vpn-operations.md), the ntfy identity
workflows in [Operate ntfy notifications](ntfy-operations.md), the Portainer credential
workflows in [Operate Portainer](portainer-operations.md), and the provider writer in
[Operate Pi-hole ExternalDNS](pihole-externaldns-operations.md).

The age identity is not required for:

- normal source edits;
- `mise exec -- just ci`;
- validators that inspect encrypted source without decrypting it, including
  `mise exec -- just talos source-validate`;
- ordinary scoped cluster verification;
- normal Flux reconciliation of existing ciphertext; or
- other agent-owned read-oriented workflows.

The practical rule is:

```text
normal development or validation
→ no age identity

protected repository material must be read or written
→ operator loads the identity temporarily
→ operator runs the approved workflow
→ operator removes the identity from the shell environment

Flux applies existing ciphertext
→ Flux uses flux-system/sops-age
→ workstation identity is not involved
```

## Load and verify the repository identity

For a short operation, load the identity into the current shell without printing it:

```bash
printf 'SOPS age private identity: '
read -rs SOPS_AGE_KEY
printf '\n'
export SOPS_AGE_KEY
mise exec -- just repo secrets
```

When the operation is complete, remove it from the shell:

```bash
unset SOPS_AGE_KEY
```

For repeated workstation operations, SOPS also supports an external file:

```bash
export SOPS_AGE_KEY_FILE=/secure/path/repository-age-key.txt
mise exec -- just repo secrets
```

Keep that file outside every repository checkout and protect it so only the operator can
read it. Remove the environment reference when it is no longer needed:

```bash
unset SOPS_AGE_KEY_FILE
```

### What `repo secrets` proves

`mise exec -- just repo secrets` derives a public recipient from the loaded private
identity and compares it with the repository recipient in `.sops.yaml`. It rejects a
missing or different identity without decrypting application credentials.

It does not prove that:

- an application credential is valid;
- every encrypted file can be applied successfully;
- Flux currently has the matching cluster-side identity; or
- the live cluster is reconciling encrypted Secrets.

Use the subsystem's validator and live verifier for those separate checks.

## Create or rotate an application Secret

Use the repository writer for the affected subsystem. Do not create an ad hoc plaintext
manifest or copy a decrypted Secret into the worktree.

A typical operator workflow is:

1. Work from the intended feature worktree.
2. Load the repository age identity and the required credential from its approved
   external source.
3. Run the subsystem's guarded `mise exec -- just repo …-secrets` workflow.
4. Review the resulting ciphertext, metadata, rollout stamp, and other tracked changes
   without decrypting them into the repository.
5. Run the documented source validation and publish the change through a pull request.
6. After merge, let Flux reconcile and run the subsystem's live verification.
7. Remove the age identity and plaintext credential variables from the shell.

Writers validate the repository recipient and write only ciphertext to tracked Secret
paths. Some also validate an external credential, update a rollout stamp, or perform a
temporary external integration test. The relevant integration guide describes those
additional effects and confirmation values.

These workflows are operator-owned because they require the operator-held age identity
and plaintext credentials. A `*_CONFIRM` value is an execution guard; the guard itself
does not decide who has authority to run the operation.

There is no generic recipe for interactive SOPS editing. When a subsystem has no writer
and direct editing is explicitly appropriate, use the pinned CLI:

```bash
mise exec -- sops kubernetes/path/to/secret.sops.yaml
```

Do not use direct editing to bypass an established writer or its validation.

## Talos cluster identity is special

An application password or token is normally replaceable. The encrypted
[`talos/talsecret.sops.yaml`](../../talos/talsecret.sops.yaml) file instead contains the
persistent Talos cluster identity and recovery authority used to render machine and
client configuration.

```text
application credential
→ designed to be rotated or replaced

Talos identity bundle
→ identifies this cluster
→ must be preserved for rebuild and recovery
→ must not be casually regenerated
```

Regenerating the bundle would create a different Talos cluster identity. If the tracked
bundle cannot be decrypted or appears inconsistent with the cluster, stop and use the
[platform disaster-recovery runbook](../runbooks/platform-disaster-recovery.md). Do not
generate a replacement as an ordinary repair.

### Generate ignored Talos configuration

Run this only from the operator-controlled primary checkout with the matching age
identity loaded:

```bash
mise exec -- just talos generate
```

The recipe:

1. validates the tracked Talhelper inputs and SOPS policy;
2. verifies the loaded age identity with `repo secrets`;
3. lets Talhelper decrypt the tracked Talos identity locally;
4. renders ignored node configuration under `clusterconfig/`;
5. installs the generated administrator Talos client configuration at `.talos/config`
   with mode `0600`; and
6. validates the rendered configuration.

The decrypted Talos material remains ignored local output. It is not committed.
Source-only changes can use `mise exec -- just talos source-validate` without the age
identity.

## Flux cluster-side decryption

Each Flux Kustomization that consumes SOPS content names `sops-age` as its decryption
Secret. During normal operation:

```text
operator updates ciphertext through Git
→ change merges to main
→ Flux already has flux-system/sops-age
→ Flux decrypts and reconciles the Secret
```

No workstation identity or manual Secret copy is needed for routine reconciliation.

### Check the Flux canary

The repository contains a permanent encrypted, noncritical canary Secret. Its Flux
Kustomization also names `sops-age`, so a Ready canary is a visible signal that Flux
reconciled SOPS-protected source.

Use the local source check before publication:

```bash
mise exec -- just kube flux-validate
```

Use the approved scoped live verifier to confirm Flux controllers, source reconciliation,
and canary readiness:

```bash
mise exec -- just kube flux-verify
```

`flux-verify` observes the current ready state. A stronger recreation test exists for
exceptional acceptance work. It deliberately deletes only the labeled canary, asks Flux
to recreate it from encrypted Git source, and confirms that the new Secret has a new
UID. That test mutates live cluster state and is human-owned in the executable test
catalog:

```bash
FLUX_CANARY_CONFIRM='recreate:flux-system:flux-canary' \
  mise exec -- just kube flux-canary-test
```

Do not use the recreation test as a routine status check.

### Restore a missing `sops-age` Secret

`mise exec -- just bootstrap flux-sops` is an exceptional operator recovery workflow,
not part of normal application Secret rotation. It needs the matching age identity and
administrator cluster access because it reads or creates a Kubernetes Secret.

If `flux-system/sops-age` already exists and derives the expected recipient, the recipe
leaves it unchanged. If the live Secret derives a different recipient, the recipe stops
and refuses to overwrite it. If the Secret is absent, the operator must authorize the
exact creation target:

```bash
export FLUX_SOPS_CONFIRM='create:flux-system:sops-age'
mise exec -- just bootstrap flux-sops
unset FLUX_SOPS_CONFIRM
```

Keep the age identity loaded only for the duration of the recovery, then remove it from
the shell as described earlier. After recovery, run `mise exec -- just kube flux-verify`.
Use the canary recreation test only when the stronger state-changing proof is required
and separately authorized.

## Recovery

### New workstation or fresh primary checkout

1. Prepare the primary checkout with
   [Set up the operator repository and worktrees](repository-worktree-setup.md).
2. Restore the repository age identity from the operator's private store to the
   workstation environment or an owner-readable file outside the checkout.
3. Run `mise exec -- just repo secrets`.
4. Run `mise exec -- just talos generate` when administrator Talos configuration must be
   recreated.

The tracked ciphertext remains usable after a workstation loss as long as the matching
private identity is preserved.

### Lost operator age identity

The repository ciphertext cannot be decrypted without the matching private identity.
Stop and treat loss of the identity as an operator recovery incident. Do not regenerate
`talos/talsecret.sops.yaml` or replace the cluster identity as a shortcut.

### Lost Flux decryption Secret

If Git still contains the ciphertext and the operator still has the matching identity,
use the guarded `bootstrap flux-sops` recovery described above. A recipient mismatch is
not ordinary recovery; it requires a separately designed and reviewed key-rotation
workflow.

For broader platform recovery, follow
[`docs/runbooks/platform-disaster-recovery.md`](../runbooks/platform-disaster-recovery.md).

## Implementation reference

| Source | Role |
| --- | --- |
| [`.sops.yaml`](../../.sops.yaml) | Selects the public age recipient and encryption boundary for Talos and Kubernetes files. |
| [`talos/talsecret.sops.yaml`](../../talos/talsecret.sops.yaml) | Stores the fully encrypted persistent Talos identity. |
| [`talos/mod.just`](../../talos/mod.just) | Implements source validation and Talos generation. |
| [`.just/repository.just`](../../.just/repository.just) | Implements identity validation and application Secret writers. |
| [`.just/bootstrap.just`](../../.just/bootstrap.just) | Implements guarded Flux SOPS recovery. |
| [`kubernetes/apps/flux-system/flux-canary/README.md`](../../kubernetes/apps/flux-system/flux-canary/README.md) | Describes the permanent encrypted reconciliation canary. |
| [`scripts/validate/flux.sh`](../../scripts/validate/flux.sh) | Validates the local Flux/SOPS canary source. |
| [`scripts/verify/flux.sh`](../../scripts/verify/flux.sh) | Verifies live Flux and canary readiness. |
