# Prepare a clone and worktree

Use this guide to prepare the main clone, create a linked feature worktree, and install
cluster credentials when a task needs them. Repository policy in [`AGENTS.md`](../../AGENTS.md)
defines who may perform each action.

## Prepare a fresh main clone

Prerequisites are Git, Homebrew, Bash 5 or newer, repository access, and the
operator-held SOPS age identity.

1. Review and trust the repository configuration:

   ```bash
   mise trust
   ```

2. Install the locked toolchain. `just` is mise-managed and is not available before
   this step completes:

   ```bash
   mise install --locked
   ```

3. Install the shared commit-time hooks:

   ```bash
   mise exec -- just repo hooks
   ```

4. Load `SOPS_AGE_KEY` or an owner-readable `SOPS_AGE_KEY_FILE` from outside the
   repository, then verify that the identity matches the repository:

   ```bash
   mise exec -- just repo secrets
   ```

   See [SOPS secret handling](sops.md). Never put the private identity in the
   checkout.

5. Generate the ignored Talos machine configurations and the main clone's Talos
   client credential:

   ```bash
   mise exec -- just talos generate
   ```

6. Retrieve the main clone's administrator Kubernetes kubeconfig:

   ```bash
   mise exec -- just talos kubeconfig
   ```

7. Run the canonical cluster-independent gate:

   ```bash
   mise exec -- just ci
   ```

Unset shell-exported secret material when the operator task is complete. The main clone
may retain its ignored administrator credentials; linked worktrees do not receive
copies of them.

## Create a linked worktree

From the main clone, create a feature branch and linked worktree with the configured
worktree manager:

```bash
wt switch -c <branch>
```

Open the created worktree, then trust and validate it:

```bash
mise trust
mise exec -- just ci
```

The expected layout uses a sibling `homelab-talos.<branch>` directory. A runtime-managed
or operator-supplied worktree also satisfies the isolation requirement. Work only inside
the worktree assigned to the task and preserve unrelated changes.

Before removing a worktree, inspect its Git state and preserve useful commits on the
appropriate feature branch. Do not remove, move, repair, or prune a worktree owned by
another active task or whose ownership is uncertain.

## Install scoped worktree access

A new linked worktree has no Talos or Kubernetes credential. Most source-only work needs
none. When an approved live verification needs scoped access, run this command inside
that worktree:

```bash
mise exec -- just talos kubeconfig
```

The worktree path creates an `os:reader` Talos credential and the
`homelab-observer`/`homelab-diagnostic` Kubernetes contexts in ignored
worktree-local files. It does not copy an administrator identity. Rerun the same command
in the worktree to replace an expired task-scoped credential.

Use only the credential tier authorized for the verifier. See
[Agent cluster access](agent-cluster-access.md) for tier semantics and verifier
selection.

## Bootstrap and recovery interfaces

The guarded Talos and Flux bootstrap commands are documented by
[`talos/README.md`](../../talos/README.md),
[`kubernetes/README.md`](../../kubernetes/README.md), and the
[platform recovery runbook](../runbooks/recovery.md). Use the pinned
`mise exec -- just ...` interfaces. Do not replace them with ad hoc raw cluster
commands.

## Editor window identity

This optional VS Code user-level setting distinguishes windows whose sibling paths share
the same prefix:

```json
{
  "window.title": "${activeRepositoryBranchName} — ${activeRepositoryName}"
}
```

Do not add a repository `.vscode/` file for this personal setting.
