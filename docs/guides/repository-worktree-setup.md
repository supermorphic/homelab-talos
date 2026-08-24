# Repository and worktree setup

## Purpose and mental model

Use this guide to prepare a new primary checkout and to create or receive an isolated
worktree for repository tasks. It covers local repository setup. It does not bootstrap,
repair, or change the live Talos or Flux platform.

Repository policy in [`AGENTS.md`](../../AGENTS.md) defines who may perform each action.
The local setup model is:

```text
one-time operator setup
        ↓
primary checkout with operator/admin capabilities

per-task worktree setup
        ↓
isolated source workspace
        ↓
starts with no cluster credentials

live cluster access becomes necessary
        ↓
scoped worktree credentials are created on demand
```

The primary checkout and linked worktrees have different authority:

```text
primary checkout
  → operator-controlled checkout
  → Talos os:admin
  → Kubernetes homelab-admin

linked worktree
  → source and task isolation
  → no cluster credentials by default

linked worktree when approved live access is needed
  → Kubernetes homelab-observer and homelab-diagnostic
  → Talos os:reader
```

## One-time operator setup

Perform this procedure when preparing a new machine or fresh primary checkout. Do not
repeat it for every task or linked worktree.

Prerequisites are Git, Homebrew, Bash 5 or newer, repository access, and the
operator-held SOPS age identity. Keep the age identity outside the repository.

1. Review and trust the repository's mise configuration:

   ```bash
   mise trust
   ```

   Mise will not load untrusted configuration that can affect the local execution
   environment. Trust the file only after reviewing it. The trust decision applies to
   the equivalent configuration path in linked Git worktrees.

2. Install the versions resolved by the repository lockfile:

   ```bash
   mise install --locked
   ```

   This installs the pinned local tools declared by the repository. `just` is one of
   those tools and is not available through mise until this step completes.

3. Install the shared commit-time hooks:

   ```bash
   mise exec -- just repo hooks
   ```

   The recipe installs the pre-commit environments, places the hooks under Git's shared
   common directory, and sets the clone's `core.hooksPath`. One successful installation
   covers the primary checkout and all of its linked worktrees.

4. Load `SOPS_AGE_KEY` or an owner-readable `SOPS_AGE_KEY_FILE` from outside the
   repository, then verify it:

   ```bash
   mise exec -- just repo secrets
   ```

   This read-only check derives the public age recipient from the loaded private
   identity and compares it with `.sops.yaml`. It does not generate or store the private
   identity. See [SOPS secret operations](sops-secret-operations.md).

5. Generate and validate the ignored Talos configuration:

   ```bash
   mise exec -- just talos generate
   ```

   The recipe validates the tracked Talhelper inputs, decrypts the tracked Talos secret
   bundle in memory, rebuilds the ignored node configurations under `clusterconfig/`,
   and installs the generated Talos administrator client configuration at
   `.talos/config` with mode `0600`.

6. Retrieve the Kubernetes administrator kubeconfig:

   ```bash
   mise exec -- just talos kubeconfig
   ```

   When run from the primary checkout, this command uses `.talos/config` to retrieve
   and replace the ignored `.kube/config`. The resulting `homelab-admin` context
   authenticates as the Kubernetes `admin` user in the `system:masters` group.

7. Run the canonical cluster-independent validation gate:

   ```bash
   mise exec -- just ci
   ```

   This verifies the current repository source without requiring a kubeconfig, the age
   identity, or live cluster access.

Unset shell-exported secret material after the operator task is complete.

## What the primary checkout contains afterward

The operator-controlled primary checkout may retain these ignored local artifacts:

- `clusterconfig/nuc1.yaml`, `clusterconfig/nuc2.yaml`, and
  `clusterconfig/nuc3.yaml`: generated Talos machine configuration.
- `.talos/config`: the Talos `os:admin` client identity.
- `.kube/config`: the Kubernetes `homelab-admin` context.

These files contain administrator credentials or generated secret material. Do not
commit, copy into a linked worktree, or supply them to an agent task. The SOPS age
identity remains operator-held and outside every checkout.

The behavior of `mise exec -- just talos kubeconfig` depends on where it runs. The
recipe compares the current Git worktree root with Git's primary-checkout root:

- In the primary checkout, it follows the administrator download path described above.
- In a linked worktree, it follows the scoped credential path described below.

The identical command therefore does not imply identical authority.

## Create or receive a task worktree

Implementation work normally belongs in an isolated task worktree rather than the
primary checkout.

### Operator-created worktree

When the operator creates a new feature branch and worktree manually, run the configured
Worktrunk command from the primary checkout:

```bash
wt switch -c <branch>
```

`-c` creates the branch and linked worktree. Worktrunk selects the worktree path and
switches the shell to it. The current local convention produces a sibling path such as
`homelab-talos.<branch>`.

### Runtime- or agent-provided worktree

A supported runtime or agent may already have created and assigned a linked worktree.
Use that assigned path. Do not recreate, relocate, repair, replace, or remove it from the
primary checkout. One task must not modify or remove another task's worktree.

In either case, inspect the Git branch and worktree state before starting. Preserve
unrelated changes and stop if the assigned state is inconsistent or its ownership is
uncertain.

## Trust and validate the worktree

Mise shares the primary checkout's trust decision with equivalent configuration paths in
linked Git worktrees. A normal linked worktree therefore does not need another
`mise trust` command. A separate clone is not a linked worktree and needs its own
one-time review and trust decision.

From the assigned worktree, run:

```bash
mise exec -- just ci
```

This proves that the source passes the canonical local gate before the task adds any
live cluster dependency. It does not create cluster credentials or contact the cluster.

## Cluster access is not installed by default

A new linked worktree contains neither `.kube/config` nor `.talos/config`. Most source,
documentation, and cluster-independent validation work should proceed without them.

The primary checkout's `homelab-admin` and Talos `os:admin` credentials are never copied
into the worktree. The absence of credentials is intentional; creating a worktree does
not grant cluster access.

## Add scoped access only when needed

When an approved agent-owned task actually needs live inspection or scoped verification,
the agent that owns the linked worktree must run this command itself from that worktree:

```bash
mise exec -- just talos kubeconfig
```

The operator normally does not run this scoped bootstrap on the agent's behalf. The
primary checkout must already contain its valid administrator credential pair because
the installer uses that authority to mint narrower credentials, but it does not copy
either administrator identity into the worktree.

The linked-worktree path creates ignored, worktree-local files with mode `0600`:

- `.kube/config` contains 30-day credentials for exactly
  `homelab-observer` and `homelab-diagnostic`; `homelab-observer` is current.
- `.talos/config` contains a 90-day Talos credential with exactly the `os:reader` role.

Re-run the same command from the linked worktree when an approved task needs to replace
expired scoped credentials. If the prerequisite primary-checkout administrator
credentials are missing, the agent stops and asks the operator to restore that
operator-owned prerequisite; the operator still does not run the worktree command for
the agent.

See [Agent cluster access](agent-cluster-access.md) for observer and diagnostic
permissions, approved verifier use, and the boundary for insufficient scoped access.

## Operator and agent responsibilities

The operator controls initial machine and primary-checkout preparation, the SOPS age
identity, administrator credentials, and explicitly operator-run privileged or recovery
workflows.

Within an assigned task, an agent proceeds autonomously with repository work allowed by
`AGENTS.md`. When approved live access becomes necessary, the agent creates and uses its
own scoped worktree credentials and runs approved scoped verification. Confirmation
prompts, sandbox approval, or use of `mise exec -- just ...` do not change the authority
boundary by themselves.

## Remove a worktree safely

Before removal, inspect the worktree's Git state and preserve useful commits on an
appropriate feature branch. Confirm that the worktree is no longer assigned to an active
task and that its ownership is certain.

For an operator-created Worktrunk worktree, remove the selected clean worktree through
the manager:

```bash
wt remove <branch>
```

Do not use Worktrunk's force-removal or force-delete options as a shortcut around dirty
or unmerged work. Do not move, repair, prune, or remove a runtime-owned worktree unless
the owning task has completed and its useful work has been preserved or intentionally
discarded with appropriate authority.

## Bootstrap and recovery interfaces

Preparing the repository or a linked worktree does not authorize or perform Talos, Flux,
or application bootstrap and recovery.

Use [`talos/README.md`](../../talos/README.md),
[`kubernetes/README.md`](../../kubernetes/README.md), and the
[platform recovery runbook](../runbooks/recovery.md) for those exceptional workflows.
Use their guarded `mise exec -- just ...` interfaces and stated operator boundaries.

## Optional editor window identity

This optional VS Code user-level setting distinguishes windows whose sibling paths share
the same prefix:

```json
{
  "window.title": "${activeRepositoryBranchName} — ${activeRepositoryName}"
}
```

Keep this personal setting outside the repository. Do not add a repository `.vscode/`
policy surface for it.
