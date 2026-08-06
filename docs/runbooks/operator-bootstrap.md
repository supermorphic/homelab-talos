# Operator bootstrap and worktree lifecycle

This runbook is the current operator procedure for preparing the main clone, creating a
linked feature worktree, and installing credentials on demand. Repository agents do not
create, remove, move, prune, or repair worktrees.

## Fresh main clone

Prerequisites are Git, Homebrew, Bash 5 or newer, access to the repository, and the
operator-held SOPS age identity. Install mise and Bash before entering this sequence.

From a fresh clone of `main`, follow this order exactly:

1. Review and trust the repository configuration.

   ```bash
   mise trust
   ```

2. Install the locked toolchain. `just` is mise-managed, so it is unavailable before
   this step completes.

   ```bash
   mise install --locked
   ```

3. Install the repository's commit-time hooks.

   ```bash
   mise exec -- just repo hooks
   ```

   The recipe installs the hook in Git's shared common directory and configures
   `core.hooksPath` to use it. One installation from the main clone covers linked
   worktrees; rerunning the command from either location is safe.

4. Export the operator-held SOPS identity into the current shell. Use either
   `SOPS_AGE_KEY` or an owner-readable `SOPS_AGE_KEY_FILE` outside the repository; never
   create an age-key file in the checkout. See [`docs/sops.md`](../sops.md).

5. Confirm that the exported identity matches the repository's encrypted material.

   ```bash
   mise exec -- just repo secrets
   ```

6. Generate the ignored Talos machine configurations and the main clone's ignored admin
   Talos client credential from the declared, encrypted source.

   ```bash
   mise exec -- just talos generate
   ```

7. Retrieve the admin Kubernetes kubeconfig into the main clone's ignored `.kube/config`.

   ```bash
   mise exec -- just talos kubeconfig
   ```

8. Run the canonical cluster-independent gate.

   ```bash
   mise exec -- just ci
   ```

Unset shell-exported secret material when the operator task is complete. The main clone
retains admin credentials; linked worktrees never receive copies of them.

## New linked worktree

Only the operator runs worktrunk lifecycle commands. From the main clone, create the
branch and linked worktree:

```bash
wt switch -c <branch>
```

Open the worktree worktrunk created, then trust and validate it:

```bash
mise trust
mise exec -- just ci
```

The adopted layout is the sibling `homelab-talos.<branch>` convention. Agents work only
inside the worktree assigned to their session. They do not run `wt switch -c`, `wt
remove`, or raw Git worktree lifecycle commands. No worktree-management agent skill is
installed.

Only the operator runs removal after reviewing worktree and branch state:

```bash
wt remove
```

Any future project-level worktrunk setting belongs in a tracked `.config/wt.toml`, not in
an agent skill or a per-worktree editor file.

## On-demand worktree access

A new linked worktree has no Talos or Kubernetes credential. Most source-only work needs
none. When scoped live access is required, the operator runs this command **inside that
worktree**:

```bash
mise exec -- just talos kubeconfig
```

In a linked worktree the recipe installs observer and diagnostic Kubernetes contexts and
an `os:reader` Talos credential; it does not copy admin credentials. Credential minting
remains operator-owned even when an agent will run an authorized scoped verifier.

To refresh an expired or intentionally replaced worktree credential, rerun the same
command in that worktree:

```bash
mise exec -- just talos kubeconfig
```

See [`agent-cluster-access.md`](agent-cluster-access.md) for tier semantics and verifier
selection.

## Editor window identity

Use this VS Code **user-level** setting so windows remain distinguishable even when the
sibling paths share the same prefix:

```json
{
  "window.title": "${activeRepositoryBranchName} — ${activeRepositoryName}"
}
```

Do not create a repository `.vscode/` file for this personal setting; that directory is
ignored.

## Operator filesystem cleanup outside this repository

The leftover `homelab-talos-worktrees/` slot from the retired layout is not modified by
this repository change. Removing it is an operator filesystem action after independently
confirming it contains no needed worktree or uncommitted data.
