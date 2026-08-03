# Repository and Workstation Recovery

## Source Recovery

Clone the private repository and install the toolchain from its lockfile:

```bash
brew install mise
mise trust
mise install --locked
mise exec -- just repo verify
```

The `manual-talos-v1.13.2` tag preserves the historical Git state of the manual
build. Its artifacts are not present on the current branch. The original SSDs
are the physical rollback path and must remain labeled by node.

## Restore SOPS Access

Retrieve the password-manager item named `homelab-talos SOPS age key`. Load it
for the current shell without placing it in the repository:

```bash
export SOPS_AGE_KEY='AGE-SECRET-KEY-...'
mise exec -- just repo secrets
```

For longer operations, use an owner-readable file outside the repository:

```bash
export SOPS_AGE_KEY_FILE=/secure/path/homelab-talos-age.txt
mise exec -- just repo secrets
```

Only the active public recipient is committed on the current branch. A lost
private key makes current repository secrets unrecoverable. Any deliberate
recovery from the historical rollback tag requires the separate identity that
encrypted that historical state.

## Recreate Generated State

Rendered machine configs and talosconfig can be recreated from Git plus the
repository age identity:

```bash
mise exec -- just talos generate
```

The recipe verifies the age identity, renders `clusterconfig/nuc1.yaml` through
`nuc3.yaml`, installs the generated Talos client credential at `.talos/config`,
then performs strict metal-mode and policy validation. These outputs and the later
`.kube/config` remain ignored. Never recover them by committing plaintext copies.

Phase-specific rebuild and recovery evidence is maintained under `docs/`.

## Recover Flux Source Access

Flux runtime Git access uses the private key in the
`flux-system/flux-system` Secret and a matching read-only GitHub deploy key. The
bootstrap PAT is not stored in the cluster and is not needed for normal
reconciliation. The canonical source endpoint is
`ssh://git@ssh.github.com:443/supermorphic/homelab-talos`; GitHub's SSH
port 443 avoids environments that block or time out port 22.

If the URL already uses port 443 but source-controller reports
`knownhosts: key is unknown`, preserve the deploy key and repair only its host
trust through the guarded workflow:

```bash
export FLUX_SSH_KNOWN_HOSTS_CONFIRM='repair:flux-system:known-hosts:ssh.github.com:443'
mise exec -- just bootstrap flux-ssh-known-hosts
unset FLUX_SSH_KNOWN_HOSTS_CONFIRM
```

If the deploy key is deleted from GitHub or its cluster Secret is lost, load the
repository-scoped fine-grained PAT, run the read-only preflight, and rerun the
guarded bootstrap workflow. Its `--reconcile` behavior restores the canonical
Flux `2.9.2` manifests and matching read-only SSH key without granting Git write
access:

```bash
export GITHUB_TOKEN='github_pat_...'
export FLUX_BOOTSTRAP_CONFIRM='bootstrap:flux:prod:supermorphic/homelab-talos:read-only'
mise exec -- just kube flux-preflight
mise exec -- just bootstrap flux
unset FLUX_BOOTSTRAP_CONFIRM GITHUB_TOKEN
```

If the PAT itself is lost, create a replacement with repository Administration
and Contents read/write access. Replacing or removing that PAT has no effect on
running Flux after the SSH deploy key exists.

## Recover Flux SOPS Access

If `flux-system/sops-age` is absent but the password-manager identity remains
available, recreate it through the guarded workflow:

```bash
export SOPS_AGE_KEY='AGE-SECRET-KEY-...'
export FLUX_SOPS_CONFIRM='create:flux-system:sops-age'
mise exec -- just bootstrap flux-sops
unset FLUX_SOPS_CONFIRM SOPS_AGE_KEY
```

The recipe refuses to overwrite a Secret that derives a different public
recipient. That condition is a rotation, not ordinary recovery: stop, preserve
the old key, re-encrypt every affected SOPS document for the planned recipient,
and add a dedicated reviewed rotation workflow before changing the live Secret.
Do not delete a still-needed identity or perform an ad hoc `kubectl` overwrite.

If a Phase 7 provider credential is rotated, load the replacement Cloudflare
token or Pi-hole application password and rerun the guarded
`just repo phase7-secrets` writer. It validates both providers and replaces both
tracked manifests with fresh SOPS ciphertext. Review, validate, commit, and push
the change; Flux performs the live Secret update. See
[`phase-7-foundation.md`](phase-7-foundation.md) for the exact inputs and guard.
After a Pi-hole reinstall or TLS rotation, refresh and review its public CA with
`just repo pihole-ca-refresh` before rotating the application password. The full
fail-closed procedure is in
[`pihole-integration.md`](pihole-integration.md).

After either recovery, use `just kube flux-status`, `just kube flux-verify`, and
the confirmed `just kube flux-canary-test` gate described in
[`phase-6-flux.md`](phase-6-flux.md).
